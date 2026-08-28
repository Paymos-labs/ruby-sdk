# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../lib/paymos'
require_relative 'payment_channel_fixtures'

# The channel list and the deposit feed are two DIFFERENT paginations, and both live in this file on
# purpose: the list terminates on a null cursor (test 9), the feed never does (tests 3 and 4).
class PaymentChannelsTest < Minitest::Test
  include PaymentChannelFixtures

  def test_creating_the_same_channel_twice_returns_the_channel_both_times
    client = stub_client([201, payment_channel_json], [200, payment_channel_json])

    first = client.payment_channels.create(project_id: 'prj_1', external_id: 'customer-42')
    second = client.payment_channels.create(project_id: 'prj_1', external_id: 'customer-42')

    assert_equal 'pc_1', first.id
    assert_equal 'pc_1', second.id
    assert_equal 'TRC20', first.networks.first.network
    assert_equal '1.00', first.networks.first.tokens.first.minimum_deposit
    assert_equal({ 'project_id' => 'prj_1', 'external_id' => 'customer-42' }, JSON.parse(@calls.first[3]))
  end

  def test_block_returns_the_updated_channel
    client = stub_client([200, payment_channel_json(is_accepting_payments: false)])

    channel = client.payment_channels.block('pc_1')

    refute channel.is_accepting_payments
    assert_equal ['POST', '/v1/payment-channels/pc_1/block'], @calls.first.first(2)
  end

  def test_unblock_returns_the_updated_channel
    client = stub_client([200, payment_channel_json(is_accepting_payments: true)])

    channel = client.payment_channels.unblock('pc_1')

    assert channel.is_accepting_payments
    assert_equal ['POST', '/v1/payment-channels/pc_1/unblock'], @calls.first.first(2)
  end

  def test_an_empty_feed_page_still_carries_a_cursor_to_resume_from
    client = stub_client([200, '{"items":[],"next_cursor":"cur_2"}'])

    page = client.payment_channel_deposits.read

    assert_empty page.items
    assert_equal 'cur_2', page.next_cursor
    assert_nil page.blocked
  end

  def test_a_feed_page_without_a_cursor_is_rejected
    client = stub_client([200, '{"items":[],"next_cursor":null}'])

    assert_raises(Paymos::Error) { client.payment_channel_deposits.read }
  end

  def test_a_blocked_feed_page_surfaces_which_deposit_and_why
    body = '{"items":[],"next_cursor":"cur_2","blocked":{"deposit_id":"pcd_9","reason":"not_confirmed"}}'
    client = stub_client([200, body])

    page = client.payment_channel_deposits.read(cursor: 'cur_1')

    assert_equal 'cur_2', page.next_cursor
    assert_equal 'pcd_9', page.blocked.deposit_id
    assert_equal 'not_confirmed', page.blocked.reason
  end

  def test_every_filter_reaches_the_wire_in_snake_case
    client = stub_client([200, '{"items":[],"next_cursor":null}'], [200, '{"items":[],"next_cursor":"cur_2"}'])

    client.payment_channels.list(limit: 10, cursor: 'cur_1', status: %w[active blocked],
                                 external_id: 'customer-42', project_id: 'prj_1')
    client.payment_channel_deposits.read(limit: 10, cursor: 'cur_1', project_id: 'prj_1',
                                         payment_channel_id: 'pc_1', confirmed_from: 1_700_000_000)

    assert_equal '/v1/payment-channels?cursor=cur_1&external_id=customer-42&limit=10&project_id=prj_1' \
                 '&status=active&status=blocked', @calls.first[1]
    assert_equal '/v1/payment-channel-deposits?confirmed_from=1700000000&cursor=cur_1&limit=10' \
                 '&payment_channel_id=pc_1&project_id=prj_1', @calls.last[1]
  end

  def test_ids_are_path_encoded_not_query_encoded
    client = stub_client([200, payment_channel_json], [200, payment_channel_deposit_json])

    client.payment_channels.get('pc a/b')
    client.payment_channel_deposits.get('pcd a/b')

    assert_equal '/v1/payment-channels/pc%20a%2Fb', @calls.first[1]
    assert_equal '/v1/payment-channel-deposits/pcd%20a%2Fb', @calls.last[1]
    assert(@calls.none? { |call| call[1].include?('?') })
  end

  def test_simulate_sends_network_and_omits_stage_when_unset
    client = stub_client([200, payment_channel_deposit_json], [200, payment_channel_deposit_json])
    channels = client.payment_channels

    deposit = channels.simulate_deposit('pc_1', amount: '100.00', currency: 'USDT', network: 'TRC20')
    channels.simulate_deposit('pc_1', amount: '100.00', currency: 'USDT', network: 'TRC20', stage: 'confirming')

    assert_equal 'pcd_1', deposit.id
    assert_equal '/v1/sandbox/payment-channels/pc_1/simulate-deposit', @calls.first[1]
    body = JSON.parse(@calls.first[3])
    assert_equal 'TRC20', body['network']
    refute body.key?('stage')
    assert_equal 'confirming', JSON.parse(@calls.last[3])['stage']
  end

  def test_an_unknown_simulation_stage_is_rejected_before_the_request
    channels = stub_client([200, payment_channel_deposit_json]).payment_channels

    assert_raises(ArgumentError) do
      channels.simulate_deposit('pc_1', amount: '100.00', currency: 'USDT', network: 'TRC20', stage: 'settled')
    end
    assert_empty @calls
  end

  def test_the_channel_list_iterator_terminates
    first = JSON.generate(items: [payment_channel(id: 'pc_1')], next_cursor: 'cur_2')
    last = JSON.generate(items: [payment_channel(id: 'pc_2')], next_cursor: nil)
    client = stub_client([200, first], [200, last])

    channels = client.payment_channels.each(max_pages: 5).to_a

    assert_equal %w[pc_1 pc_2], channels.map(&:id)
    assert_equal 2, @calls.length
  end

  private

  def stub_client(*responses)
    @calls = []
    transport = lambda do |method, url, headers, body, _timeout|
      @calls << [method, URI(url).request_uri, headers, body]
      status, response_body = responses.shift
      Paymos::Response.new(status: status, body: response_body, headers: {})
    end
    Paymos::Client.new(api_key: 'pk', api_secret: 'sk', transport: transport, clock: -> { 1_700_000_000 })
  end
end
