# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../lib/paymos'

module RefundFixtures
  CONTRACT = JSON.parse(File.read(File.expand_path('../conformance/contract.json', __dir__)))
  VECTORS = CONTRACT.fetch('vectors').fetch('refunds')

  private

  def stub_client(*responses)
    @calls = []
    @sleeps = []
    transport = lambda do |method, url, headers, body, _timeout|
      @calls << [method, URI(url).request_uri, headers, body]
      response = responses.shift
      raise response if response.is_a?(Exception)
      raise 'Unexpected HTTP request' if response.nil?

      status, response_body = response
      Paymos::Response.new(status: status, body: JSON.generate(response_body),
                           headers: { 'Retry-After' => '0', 'Cache-Control' => 'private, no-store' })
    end
    Paymos::Client.new(api_key: 'pk', api_secret: 'sk', transport: transport,
                       clock: -> { 1_700_000_000 }, base_delay: 0, sleeper: ->(delay) { @sleeps << delay })
  end

  def create_args
    VECTORS.dig('create', 'body').transform_keys(&:to_sym)
  end

  def overpayment_args
    VECTORS.dig('overpayment', 'body').transform_keys(&:to_sym)
  end

  def refund(**attributes)
    {
      withdrawal_id: 'wdr_1', invoice_id: create_args[:invoice_id], mode: 'full',
      external_order_id: create_args[:external_order_id], status: 'created', is_final: false, is_test: true,
      amount: '120', currency: 'USDT', network: 'TRC20', destination_address: 'first-sender',
      first_sender: 'first-sender', created_at: 1_700_000_000
    }.merge(attributes)
  end

  def problem(status:, code:, **attributes)
    {
      type: "https://api.paymos.io/problems/#{code}", title: 'Request failed',
      status: status, detail: 'The refund request could not be completed.', code: code
    }.merge(attributes)
  end

  def assert_signed(call)
    method, request_uri, headers, body = call
    path, query = request_uri.split('?', 2)
    timestamp = headers.fetch('X-Request-Timestamp')
    hash = body.nil? ? '' : Digest::SHA256.hexdigest(body)
    canonical = [timestamp, method, path, query ? "?#{query}" : '', hash].join("\n")
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', 'sk', canonical))

    assert_equal '1700000000', timestamp
    assert_equal "HMAC-SHA256 pk:#{signature}", headers.fetch('Authorization')
  end
end

class RefundCreateTest < Minitest::Test
  include RefundFixtures

  def test_simulate_terminal_statuses_preserves_signed_request_and_current_refund_fields
    address = 'UQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPuwA'
    %w[completed failed cancelled].each do |status|
      wire = refund(status: status, is_final: true, network: 'TON', destination_address: address,
                    first_sender: address, type: 'refund', project_id: 'prj_1')
      client = stub_client([200, wire])
      result = client.refunds.simulate('wdr/1 ?', status)
      assert_equal status, result.status
      assert_equal address, result.destination_address
      assert_equal address, result.first_sender
      assert_equal 'refund', result.type
      assert_equal 'prj_1', result.project_id
      assert_equal ['POST', '/v1/sandbox/refunds/wdr%2F1%20%3F/simulate'], @calls[0].first(2)
      assert_equal({ 'status' => status }, JSON.parse(@calls[0][3]))
      assert_signed(@calls[0])
    end
  end

  def test_full_create_and_replay_send_the_same_signed_mode_and_key
    vector = VECTORS.fetch('create')
    client = stub_client([vector['new_status'], refund], [vector['replay_status'], refund])

    first = client.refunds.create(**create_args)
    replay = client.refunds.create(**create_args)

    assert_instance_of Paymos::Refund, first
    assert_nil first.type
    assert_nil first.project_id
    assert_equal '120', first.amount
    assert_equal first.to_h, replay.to_h
    assert_equal vector['body'], JSON.parse(@calls.first[3])
    assert_equal @calls.first[3], @calls.last[3]
    assert_equal [vector['method'], vector['path']], @calls.first.first(2)
    @calls.each { |call| assert_signed(call) }
  end

  def test_overpayment_twenty_completes_before_full_one_hundred
    invoice = {
      invoice_id: create_args[:invoice_id], project_id: 'prj_1', status: 'paid_over',
      is_final: true, is_test: true, payment_url: 'https://pay.paymos.io/i/inv_1',
      order: { external_id: 'order_1', amount: '100', currency: 'USDT' },
      payment: { currency: 'USDT', network: 'TRC20', chain_id: 728_126_428, expected: '100', paid: '120' },
      created_at: 1_700_000_000, updated_at: 1_700_000_000
    }
    over = refund(withdrawal_id: 'wdr_over', mode: 'overpayment', amount: '20',
                  external_order_id: overpayment_args[:external_order_id])
    completed = over.merge(status: 'completed', is_final: true, completed_at: 1_700_000_010)
    client = stub_client([200, invoice], [201, over], [200, completed], [200, completed],
                         [201, refund(withdrawal_id: 'wdr_full', amount: '100')])

    paid = client.invoices.get(create_args[:invoice_id])
    excess = client.refunds.create(**overpayment_args)
    client.withdrawals.simulate_completion(excess.withdrawal_id)
    settled = client.refunds.get(excess.withdrawal_id)
    remaining = client.refunds.create(**create_args)

    assert_equal '120', paid.payment.paid
    assert_equal '100', paid.payment.expected
    assert_equal '20', excess.amount
    assert_equal 'completed', settled.status
    assert_equal '100', remaining.amount
    assert_equal %w[wdr_over wdr_full], [excess.withdrawal_id, remaining.withdrawal_id]
    assert_equal 'overpayment', excess.mode
    assert_equal 'full', remaining.mode
    assert excess.is_test
    assert remaining.is_test
    assert_equal overpayment_args.transform_keys(&:to_s), JSON.parse(@calls[1][3])
    assert_equal create_args.transform_keys(&:to_s), JSON.parse(@calls.last[3])
    assert_equal ['POST', '/v1/sandbox/withdrawals/wdr_over/simulate-completion'], @calls[2].first(2)
    assert_nil @calls[2][3]
    @calls.each { |call| assert_signed(call) }
  end

  def test_sandbox_completion_can_be_replayed_for_the_same_refund_id
    completed = refund(status: 'completed', is_final: true, completed_at: 1_700_000_010)
    client = stub_client([200, completed], [200, completed], [200, completed])

    first = client.withdrawals.simulate_completion('wdr_1')
    replay = client.withdrawals.simulate_completion('wdr_1')
    current = client.refunds.get('wdr_1')

    assert_equal first.to_h, replay.to_h
    assert_equal first.withdrawal_id, current.withdrawal_id
    assert current.is_final
    assert current.is_test
    assert_equal 'completed', current.status
    assert_equal @calls.first.first(2), @calls[1].first(2)
  end

  def test_response_is_readonly_and_preserves_precise_decimal_strings
    amount = '12345678901234567890.123456789012345678'
    client = stub_client([201, refund(amount: amount, fee: '0.000000000000000001')])

    result = client.refunds.create(**create_args)

    assert_equal amount, result.amount
    assert_equal '0.000000000000000001', result.fee
    assert_equal 'USDT', result.currency
    assert_equal 'TRC20', result.network
    assert_equal 'first-sender', result.first_sender
    assert_equal 'first-sender', result.destination_address
    assert_equal 1_700_000_000, result.created_at
    assert result.frozen?
    assert result.amount.frozen?
    assert_raises(NoMethodError) { result.amount = '1' }
    assert_raises(NoMethodError) { result.mode = 'overpayment' }
    assert_raises(FrozenError) { result.amount.replace('1') }
    assert_raises(FrozenError) { result.first_sender.replace('another-sender') }
    VECTORS.dig('wire', 'required_fields').each { |field| refute_nil result[field] }
  end

  def test_missing_required_refund_fields_are_rejected
    body = refund
    body.delete(:mode)
    client = stub_client([200, body])

    assert_raises(Paymos::Error) { client.refunds.get('wdr_1') }
  end

  def test_create_rejects_financial_and_destination_arguments_before_transport
    client = stub_client

    VECTORS.dig('create', 'rejected_fields').each do |field|
      assert_raises(ArgumentError) { client.refunds.create(**create_args, field.to_sym => '1') }
    end
    assert_empty @calls
  end

  def test_create_requires_nonempty_strings_and_one_of_the_two_modes
    client = stub_client

    %i[invoice_id mode external_order_id].each do |field|
      [nil, '', ' ', 123].each do |value|
        assert_raises(ArgumentError) { client.refunds.create(**create_args, field => value) }
      end
    end
    %w[partial FULL].each do |mode|
      assert_raises(ArgumentError) { client.refunds.create(**create_args, mode: mode) }
    end
    assert_raises(ArgumentError) { client.refunds.create(invoice_id: 'inv_1', mode: 'full') }
    assert_empty @calls
  end

  def test_changing_the_mode_for_the_same_key_surfaces_structured_conflict
    vector = VECTORS.fetch('create')
    body = problem(status: 409, code: 'idempotency_conflict')
    client = stub_client([201, refund], [vector['changed_mode_status'], body])
    client.refunds.create(**create_args)

    error = assert_raises(Paymos::ConflictError) do
      client.refunds.create(**create_args, mode: 'overpayment')
    end

    assert_equal 409, error.status
    assert_equal 'idempotency_conflict', error.code
    assert_nil error.field
    assert_equal body[:detail], error.detail
    assert_equal body.transform_keys(&:to_s), error.problem
    assert_equal JSON.generate(body), error.body
    assert_equal 2, @calls.length
    assert_equal create_args[:external_order_id], JSON.parse(@calls.last[3])['external_order_id']
  end
end

class RefundReadTest < Minitest::Test
  include RefundFixtures

  def test_foreign_and_missing_ids_surface_the_same_not_found_error
    status = VECTORS.dig('get', 'foreign_or_missing_status')
    body = problem(status: status, code: 'not_found')
    client = stub_client([status, body], [status, body])

    %w[wdr_foreign wdr_missing].each do |id|
      error = assert_raises(Paymos::NotFoundError) { client.refunds.get(id) }
      assert_equal 404, error.status
      assert_equal 'not_found', error.code
      assert_equal body[:detail], error.detail
      assert_equal ['GET', "/v1/refunds/#{id}"], @calls.last.first(2)
      assert_signed(@calls.last)
    end
    assert_equal 2, @calls.length
  end

  def test_get_encodes_the_withdrawal_id_as_one_path_segment
    client = stub_client([200, refund])

    result = client.refunds.get('wdr a/b')

    assert_equal 'wdr_1', result.withdrawal_id
    assert_equal ['GET', '/v1/refunds/wdr%20a%2Fb'], @calls.first.first(2)
    assert_nil @calls.first[3]
    assert_signed(@calls.first)
  end

  def test_get_rejects_empty_ids_without_a_request
    client = stub_client

    [nil, '', ' ', 123].each do |id|
      assert_raises(ArgumentError) { client.refunds.get(id) }
    end
    assert_empty @calls
  end

  def test_list_sends_all_filters_and_signs_the_exact_encoded_query
    client = stub_client([200, { items: [refund], next_cursor: 'cur_next' }])
    page = client.refunds.list(invoice_id: create_args[:invoice_id], status: %w[created completed],
                               created_from: '2026-01-01T00:00:00+03:00', created_to: '2027-01-01T00:00:00Z',
                               cursor: 'cur +/=', limit: 100)

    assert_instance_of Paymos::Page, page
    assert_instance_of Paymos::Refund, page.items.first
    assert_equal 'cur_next', page.next_cursor
    assert_equal '/v1/refunds?created_from=2026-01-01T00%3A00%3A00%2B03%3A00' \
                 '&created_to=2027-01-01T00%3A00%3A00Z&cursor=cur%20%2B%2F%3D' \
                 "&invoice_id=#{create_args[:invoice_id]}&limit=100&status=completed&status=created", @calls.first[1]
    assert_nil @calls.first[3]
    assert page.frozen?
    assert page.items.frozen?
    assert page.next_cursor.frozen?
    assert_raises(FrozenError) { page.items.clear }
    assert_signed(@calls.first)
  end

  def test_list_without_filters_has_no_query_and_no_body
    client = stub_client([200, { items: [], next_cursor: nil }])

    page = client.refunds.list

    assert_empty page.items
    assert_nil page.next_cursor
    assert_equal ['GET', '/v1/refunds'], @calls.first.first(2)
    assert_nil @calls.first[3]
    assert_signed(@calls.first)
  end

  def test_list_validates_cursors_limits_statuses_and_rfc3339_periods
    client = stub_client
    invalid = [
      { limit: 0 }, { limit: 101 }, { limit: '1' }, { cursor: '' },
      { status: [] }, { status: %w[created created] },
      { created_from: 1_700_000_000 }, { created_to: 'yesterday' },
      { created_from: '2026-01-01T00:00:00' }, { created_to: '2026-13-01T00:00:00Z' },
      { created_from: '2026-01-02T00:00:00Z', created_to: '2026-01-01T00:00:00Z' },
      { created_from: '2026-01-01T03:00:00+03:00', created_to: '2026-01-01T00:00:00Z' }
    ]

    invalid.each { |filters| assert_raises(ArgumentError) { client.refunds.list(**filters) } }
    assert_empty @calls
  end

  def test_invalid_cursor_preserves_the_server_validation_error
    status = VECTORS.dig('list', 'invalid_cursor_status')
    client = stub_client([status, problem(status: status, code: 'pagination_cursor_invalid', field: 'cursor')])

    error = assert_raises(Paymos::ValidationError) { client.refunds.list(cursor: 'invalid') }

    assert_equal 400, error.status
    assert_equal 'pagination_cursor_invalid', error.code
    assert_equal 'cursor', error.field
    assert_equal 1, @calls.length
  end

  def test_validation_keeps_top_level_code_and_all_field_errors
    body = CONTRACT.dig('vectors', 'problem_details', 'multi')
    client = stub_client([400, body])

    error = assert_raises(Paymos::ValidationError) { client.refunds.create(**create_args) }

    assert_equal 400, error.status
    assert_equal body['code'], error.code
    assert_nil error.field
    assert_equal body['errors'], error.errors
    assert_equal body['detail'], error.detail
  end
end

class RefundRecoveryTest < Minitest::Test
  include RefundFixtures

  def test_payment_key_and_sandbox_errors_use_existing_error_types
    client = stub_client([403, problem(status: 403, code: 'payment_key_required')],
                         [403, problem(status: 403, code: 'not_sandbox')])

    key_error = assert_raises(Paymos::PermissionError) { client.refunds.create(**create_args) }
    sandbox_error = assert_raises(Paymos::PermissionError) { client.withdrawals.simulate_completion('wdr_1') }

    assert_equal 403, key_error.status
    assert_equal 'payment_key_required', key_error.code
    assert_equal 403, sandbox_error.status
    assert_equal 'not_sandbox', sandbox_error.code
    assert_equal 2, @calls.length
  end

  def test_uncertain_post_is_not_automatically_retried_and_can_replay_the_same_key
    client = stub_client(IOError.new('response lost'), [200, refund])

    assert_raises(Paymos::Error) { client.refunds.create(**create_args) }
    assert_equal 1, @calls.length
    replay = client.refunds.create(**create_args)

    assert_equal 'wdr_1', replay.withdrawal_id
    assert_equal 2, @calls.length
    assert_equal @calls.first[3], @calls.last[3]
    assert_empty @sleeps
    @calls.each { |call| assert_signed(call) }
  end

  def test_rate_limit_retry_keeps_the_original_key_and_payload
    client = stub_client([429, problem(status: 429, code: 'rate_limited')], [201, refund])

    result = client.refunds.create(**create_args)

    assert_equal 'wdr_1', result.withdrawal_id
    assert_equal 2, @calls.length
    assert_equal @calls.first[3], @calls.last[3]
    assert_equal [0], @sleeps
    @calls.each { |call| assert_signed(call) }
  end

  def test_unavailable_post_is_not_automatically_retried
    client = stub_client([503, problem(status: 503, code: 'unavailable')])

    error = assert_raises(Paymos::UnavailableError) { client.refunds.create(**create_args) }

    assert_equal 503, error.status
    assert_equal 'unavailable', error.code
    assert_equal 1, @calls.length
    assert_empty @sleeps
  end

  def test_iterator_reads_one_hundred_one_hundred_and_five_without_gaps
    items = (1..205).map { |id| refund(withdrawal_id: "wdr_#{id}") }
    responses = items.each_slice(100).with_index.map do |slice, index|
      [200, { items: slice, next_cursor: index < 2 ? "cur_#{index + 1}" : nil }]
    end
    client = stub_client(*responses)
    iterator = client.refunds.each(invoice_id: create_args[:invoice_id], status: 'completed', limit: 100)
    assert_empty @calls

    results = iterator.to_a

    assert_equal [100, 100, 5], VECTORS.dig('list', 'page_sizes')
    assert_equal items.map { |item| item[:withdrawal_id] }, results.map(&:withdrawal_id)
    assert_equal 205, results.map(&:withdrawal_id).uniq.length
    assert_equal 3, @calls.length
    queries = @calls.map { |call| URI.decode_www_form(URI(call[1]).query).to_h }
    assert_equal([nil, 'cur_1', 'cur_2'], queries.map { |query| query['cursor'] })
    assert(queries.all? { |query| query['invoice_id'] == create_args[:invoice_id] && query['status'] == 'completed' })
    @calls.each { |call| assert_signed(call) }
  end

  def test_iterator_rejects_a_repeated_cursor
    page = { items: [refund], next_cursor: 'same' }
    client = stub_client([200, page], [200, page])

    assert_raises(Paymos::Error) { client.refunds.each.to_a }
    assert_equal 2, @calls.length
  end

  def test_iterator_respects_its_page_bound
    client = stub_client([200, { items: [refund], next_cursor: 'cur_1' }])

    results = []
    client.refunds.each(max_pages: 1) { |item| results << item.withdrawal_id }

    assert_equal ['wdr_1'], results
    assert_equal 1, @calls.length
  end
end
