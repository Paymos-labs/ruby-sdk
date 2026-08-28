# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'openssl'
require_relative '../lib/paymos'

# The payment-channel deposit wire shape doubles as the `data` payload of every
# payment_channel.deposit.* webhook event. WebhookVerifier#construct_event only decodes the
# envelope, so `data` comes back as a plain Hash — a handler hands it to
# PaymentChannelDeposit.from(...) to get the same typed model the deposit feed returns. This test
# goes through the real verifier, HMAC and all, so it proves the whole path and not just JSON.parse.
class PaymentChannelWebhookTest < Minitest::Test
  TIMESTAMP = 1_700_000_000
  SECRET = 'whsec_test'

  # A native-coin (TRX) deposit: no contract, no attributable payer address, and no explorer link
  # was minted, so contract_address, source_address, explorer_url and
  # first_included_block_timestamp are OMITTED from the JSON below — never sent as null.
  def test_a_confirmed_deposit_webhook_round_trips_into_the_deposit_model
    data = {
      id: 'pcd_9', payment_channel_id: 'pc_1', project_id: 'prj_1',
      payment_channel_external_id: 'customer-42', status: 'confirmed', is_final: true,
      is_test: false, currency: 'TRX', network: 'TRC20', chain_id: 728_126_428,
      gross: '100.00', fee: '1.00', net: '99.00', applied_fee_percent: 1, customer_fee_percent: 0,
      tx_hash: '9a2f1c', transfer_id: 'trf_1', destination_address: 'TChannelAddress',
      block_height: 60_000_000, created_at: 1_700_000_000, updated_at: 1_700_000_100,
      confirmed_at: 1_700_000_100
    }
    raw_body = JSON.generate(
      event_id: 'evt_2', event_type: 'payment_channel.deposit.confirmed', version: 1,
      occurred_at: TIMESTAMP, data:
    )
    signature = OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{TIMESTAMP}.#{raw_body}")
    header = "t=#{TIMESTAMP},v1=#{signature}"

    event = Paymos::WebhookVerifier.new(SECRET).construct_event(header, raw_body, now: TIMESTAMP)

    assert_equal 'payment_channel.deposit.confirmed', event.event_type

    # Absent stays absent: event.data is the raw parsed Hash, so this proves the keys were
    # genuinely never sent — not merely that the decoded model happens to read them back nil.
    %w[contract_address source_address explorer_url first_included_block_timestamp].each do |key|
      refute event.data.key?(key), "expected #{key} to be absent from the raw webhook payload"
    end

    deposit = Paymos::PaymentChannelDeposit.from(event.data)

    assert_equal 'pcd_9', deposit.id
    assert_equal 'customer-42', deposit.payment_channel_external_id
    assert deposit.is_final
    assert_kind_of String, deposit.gross
    assert_kind_of String, deposit.fee
    assert_kind_of String, deposit.net
    assert_equal '100.00', deposit.gross
    assert_equal '1.00', deposit.fee
    assert_equal '99.00', deposit.net
    assert_nil deposit.contract_address
    assert_nil deposit.source_address
    assert_nil deposit.explorer_url
    assert_nil deposit.first_included_block_timestamp
  end
end
