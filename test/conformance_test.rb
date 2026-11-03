# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../lib/paymos'
require_relative 'payment_channel_fixtures'

module RefundConformanceFixtures
  private

  def withdrawal_json
    JSON.generate(
      withdrawal_id: 'wdr_1', external_order_id: 'payout_1', status: 'created',
      is_final: false, is_test: true, amount: '5.00', currency: 'USDT', network: 'tron',
      destination_address: 'address', created_at: 1_700_000_000
    )
  end
end

class SignatureConformanceTest < Minitest::Test
  include PaymentChannelFixtures
  include RefundConformanceFixtures

  CONTRACT = JSON.parse(File.read(File.expand_path('../conformance/contract.json', __dir__)))

  def test_signing_and_query_vectors
    post = CONTRACT.fetch('vectors').fetch('post_signing')
    value = Paymos::Signing.string_to_sign(
      post['timestamp'], post['method'], post['path'], post['query'], post['body']
    )
    assert_equal post['signature'], Paymos::Signing.sign(post['api_secret'], value)
    assert_equal post['authorization'],
                 Paymos::Signing.authorization(
                   post['api_key'], post['api_secret'], post['timestamp'], post['method'], post['path'],
                   post['query'], post['body']
                 )

    # An absent body signs an EMPTY last segment, never sha256(''). This vector is a POST, so an
    # SDK that shortcuts on the method ('only GET is empty') fails here.
    empty = CONTRACT.fetch('vectors').fetch('post_empty_body_signing')
    assert_equal empty['authorization'],
                 Paymos::Signing.authorization(
                   empty['api_key'], empty['api_secret'], empty['timestamp'], empty['method'],
                   empty['path'], empty['query'], empty['body']
                 )

    query = Paymos::Signing.query(status: %w[paid_over paid], project_id: 'prj/a', limit: 50)
    assert_equal CONTRACT.dig('vectors', 'get_query_signing', 'query'), query
    assert_equal 'a%20b%2F%2A~', Paymos::Signing.path_segment('a b/*~')
  end

  def test_problem_details_uses_top_level_code
    vector = CONTRACT.dig('vectors', 'problem_details', 'multi')
    error = Paymos.api_error(400, JSON.generate(vector))

    assert_equal 'validation_failed', error.code
    assert_nil error.field
    assert_equal 'field_required', error.errors.first['code']
  end

  def test_all_contract_routes_are_exposed_and_signed
    calls = []
    list_paths = ['/v1/invoices', '/v1/withdrawals', '/v1/refunds', '/v1/payment-channels']
    transport = lambda do |method, url, headers, body, _timeout|
      calls << [method, URI(url).request_uri, headers, body]
      path = URI(url).path
      response_body = if path == '/v1/time'
                        '{"server_time":1700000000}'
                      elsif path == '/v1/balances'
                        '[]'
                      elsif method == 'GET' && list_paths.include?(path)
                        '{"items":[],"next_cursor":null}'
                      elsif path == '/v1/payment-channel-deposits'
                        '{"items":[],"next_cursor":"cur_1"}'
                      elsif path.include?('payment-channel-deposits') || path.end_with?('simulate-deposit')
                        payment_channel_deposit_json
                      elsif path.include?('payment-channels')
                        payment_channel_json
                      elsif path.include?('refunds')
                        JSON.generate(JSON.parse(withdrawal_json).merge(
                                        invoice_id: 'inv_1', mode: 'full', first_sender: 'address'
                                      ))
                      elsif path.include?('invoice')
                        invoice_json
                      else
                        withdrawal_json
                      end
      Paymos::Response.new(status: 200, body: response_body, headers: {})
    end
    client = Paymos::Client.new(api_key: 'pk', api_secret: 'sk', transport: transport, clock: -> { 1_700_000_000 })

    client.system.time
    client.invoices.create(project_id: 'prj_1', amount: '10.00', currency: 'USD', external_order_id: 'order_1')
    client.invoices.get('id')
    client.invoices.list(status: %w[paid confirming])
    client.invoices.cancel('id', reason: 'merchant request')
    client.invoices.confirm_payment('id', currency: 'USDT', network: 'TRON')
    client.invoices.simulate_payment('id', stage: 'paid')
    client.withdrawals.create(destination_address: 'address', network: 'tron', currency: 'USDT', amount: '10.00',
                              external_order_id: 'payout_1')
    client.withdrawals.get('id')
    client.withdrawals.list(status: 'created')
    client.withdrawals.cancel('id', reason: 'merchant request')
    client.withdrawals.simulate_completion('id')
    client.refunds.create(invoice_id: 'inv_1', mode: 'full', external_order_id: 'refund_1')
    client.refunds.list(invoice_id: 'inv_1')
    client.refunds.get('id')
    client.refunds.simulate('id', status: 'completed')
    client.payment_channels.create(project_id: 'prj_1', external_id: 'customer-42')
    client.payment_channels.get('id')
    client.payment_channels.list(status: 'active')
    client.payment_channels.block('id')
    client.payment_channels.unblock('id')
    client.payment_channels.simulate_deposit('id', amount: '100.00', currency: 'USDT', network: 'TRC20')
    client.payment_channel_deposits.read(limit: 10)
    client.payment_channel_deposits.get('id')
    client.balances.get

    expected = CONTRACT.fetch('resources').values.flatten.map do |route|
      [route['method'], route['path'].gsub('{id}', 'id')]
    end
    actual = calls.map { |method, path, _headers, _body| [method, path.split('?', 2).first] }
    assert_equal 25, actual.length
    assert_equal expected.sort, actual.sort
    assert(calls.all? { |_method, _path, headers, _body| headers['Authorization'].start_with?('HMAC-SHA256 pk:') })
    expected_user_agent = "paymos-ruby/#{Paymos::VERSION}"
    assert(calls.all? { |_method, _path, headers, _body| headers['User-Agent'] == expected_user_agent })
    assert_equal 'a%2Fb', Paymos::Signing.path_segment('a/b')
  end

  def test_retry_and_typed_error_contract
    responses = [
      Paymos::Response.new(status: 429, body: '{"detail":"slow down"}', headers: { 'Retry-After' => '0' }),
      Paymos::Response.new(status: 200, body: invoice_json, headers: {})
    ]
    sleeps = []
    sleeper = ->(delay) { sleeps << delay }
    transport = ->(*_args) { responses.shift }
    client = Paymos::Client.new(
      api_key: 'pk', api_secret: 'sk', base_delay: 0, sleeper:, transport:
    )
    invoice = client.invoices.create(project_id: 'prj_1', amount: '10.00', currency: 'USD',
                                     external_order_id: 'order_1')
    assert_equal 'inv_1', invoice.invoice_id
    assert_equal 1, sleeps.length

    attempts = 0
    unavailable = lambda do |*_args|
      attempts += 1
      Paymos::Response.new(status: 503, body: '{"detail":"retry later"}', headers: {})
    end
    client = Paymos::Client.new(api_key: 'pk', api_secret: 'sk', transport: unavailable)
    error = assert_raises(Paymos::UnavailableError) do
      client.invoices.create(project_id: 'prj_1', amount: '10.00', currency: 'USD', external_order_id: 'order_1')
    end
    assert_equal 'unavailable', error.class.name.split('::').last.delete_suffix('Error').downcase
    assert_equal 1, attempts
  end

  def test_repeated_cursor_is_rejected
    responses = [
      Paymos::Response.new(
        status: 200,
        body: JSON.generate(items: [invoice_list_item(invoice_id: 'one')], next_cursor: 'same'),
        headers: {}
      ),
      Paymos::Response.new(status: 200, body: '{"items":[],"next_cursor":"same"}', headers: {})
    ]
    client = Paymos::Client.new(
      api_key: 'pk', api_secret: 'sk', max_retries: 0, transport: ->(*_args) { responses.shift }
    )
    iterator = client.invoices.each(max_pages: 3)
    assert_equal 'one', iterator.next.invoice_id
    assert_raises(Paymos::Error) { iterator.next }
  end

  private

  def invoice_json(invoice_id: 'inv_1')
    JSON.generate(
      invoice_id:, project_id: 'prj_1', status: 'awaiting_payment', is_final: false, is_test: true,
      payment_url: "https://pay.paymos.io/i/#{invoice_id}",
      order: { external_id: 'order_1', amount: '10.00', currency: 'USD' },
      created_at: 1_700_000_000, updated_at: 1_700_000_000
    )
  end

  def invoice_list_item(invoice_id: 'inv_1')
    {
      invoice_id:, project_id: 'prj_1', external_order_id: 'order_1', status: 'awaiting_payment',
      is_final: false, is_test: true, amount: '10.00', currency: 'USD', created_at: 1_700_000_000
    }
  end
end

class WebhookConformanceTest < Minitest::Test
  CONTRACT = SignatureConformanceTest::CONTRACT

  def test_webhook_vector
    vector = CONTRACT.dig('vectors', 'webhook')
    verifier = Paymos::WebhookVerifier.new(vector['secret'], tolerance: vector['tolerance_seconds'])
    assert verifier.verify(vector['header'], vector['raw_body'], now: vector['now'])
    event = verifier.construct_event(vector['header'], vector['raw_body'], now: vector['now'])
    assert_equal 'evt_123', event.event_id
    assert_equal 'inv_123', event.data['invoice_id']
    refute verifier.verify(vector['header'], '{}', now: vector['now'])
    refute verifier.verify("#{vector['header']},t=#{vector['timestamp']}", vector['raw_body'], now: vector['now'])
  end

  def test_signed_ton_webhook_versions_preserve_fields
    fixtures = CONTRACT.dig('vectors', 'ton_webhooks')
    vectors = fixtures.fetch('vectors')
    assert_equal 16, vectors.length
    assert_equal 16, vectors.map { |vector| vector.fetch('name') }.uniq.length
    assert_equal [1, 2], vectors.map { |vector| vector.fetch('version') }.uniq.sort
    expected_versions = {
      'invoice_raw' => 1, 'withdrawal_raw' => 1, 'refund_raw' => 1, 'channel_deposit_raw' => 1,
      'invoice_friendly' => 1, 'withdrawal_friendly' => 1, 'refund_friendly' => 1, 'channel_deposit_friendly' => 1,
      'invoice_v1' => 1, 'withdrawal_v1' => 1, 'refund_v1' => 1, 'channel_deposit_v1' => 1,
      'invoice_v2' => 2, 'withdrawal_v2' => 2, 'refund_v2' => 2, 'channel_deposit_v2' => 2
    }
    assert_equal(expected_versions, vectors.to_h { |vector| [vector.fetch('name'), vector.fetch('version')] })
    verifier = Paymos::WebhookVerifier.new(fixtures.fetch('secret'))
    fixtures.fetch('vectors').each do |vector|
      assert verifier.verify(vector.fetch('header'), vector.fetch('raw_body'), now: fixtures.fetch('now')),
             vector.fetch('name')
      event = verifier.construct_event(vector.fetch('header'), vector.fetch('raw_body'), now: fixtures.fetch('now'))
      assert_equal vector.fetch('event_id'), event.event_id
      assert_equal vector.fetch('event_type'), event.event_type
      assert_equal vector.fetch('version'), event.version
      assert_equal fixtures.fetch('now'), event.occurred_at
      vector.fetch('expect').each do |expected|
        value = expected.fetch('path').reduce(event.data) { |current, key| current.fetch(key) }
        assert_equal expected.fetch('value'), value, vector.fetch('name')
      end
      refute verifier.verify(vector.fetch('header'), "#{vector.fetch('raw_body')} ", now: fixtures.fetch('now'))
    end
  end
end

class RefundConformanceTest < Minitest::Test
  include RefundConformanceFixtures

  def test_refund_simulator_preserves_both_call_forms_and_rejects_ambiguous_status
    calls = []
    body = JSON.parse(withdrawal_json).merge('invoice_id' => 'inv_1', 'mode' => 'full',
                                             'first_sender' => 'address')
    transport = lambda do |method, url, _headers, payload, _timeout|
      calls << [method, URI(url).request_uri, JSON.parse(payload)]
      Paymos::Response.new(status: 200, body: JSON.generate(body), headers: {})
    end
    client = Paymos::Client.new(api_key: 'pk', api_secret: 'sk', transport: transport)

    %w[completed failed cancelled].each do |status|
      assert_equal 'inv_1', client.refunds.simulate('wdr /?', status).invoice_id
      assert_equal 'inv_1', client.refunds.simulate('wdr /?', status: status).invoice_id
    end
    assert_equal 6, calls.length
    assert_equal(%w[completed completed failed failed cancelled cancelled], calls.map do |call|
      call[2].fetch('status')
    end)
    assert(calls.all? do |method, path, _payload|
      method == 'POST' && path == '/v1/sandbox/refunds/wdr%20%2F%3F/simulate'
    end)

    assert_raises(ArgumentError) { client.refunds.simulate('id') }
    assert_raises(ArgumentError) { client.refunds.simulate('id', 'completed', status: 'failed') }
    assert_raises(ArgumentError) { client.refunds.simulate('id', nil, status: 'completed') }
    [nil, '', 'created', 'COMPLETED'].each do |status|
      assert_raises(ArgumentError) { client.refunds.simulate('id', status) }
      assert_raises(ArgumentError) { client.refunds.simulate('id', status: status) }
    end
    assert_equal 6, calls.length
  end

  def test_refund_model_preserves_optional_wire_fields_and_legacy_responses
    body = JSON.parse(withdrawal_json).merge('invoice_id' => 'inv_1', 'mode' => 'full',
                                             'first_sender' => 'address')
    legacy = Paymos::Refund.from(body)
    assert_nil legacy.type
    assert_nil legacy.project_id
    current = Paymos::Refund.from(body.merge('type' => 'refund', 'project_id' => 'prj_1'))
    assert_equal 'refund', current.type
    assert_equal 'prj_1', current.project_id
    assert_equal 'address', current.destination_address
  end
end
