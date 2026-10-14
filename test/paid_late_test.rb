# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../lib/paymos'

# invoice-late-payment wire contract (late-26): Invoice decodes paid_late_at (Unix seconds | nil |
# absent legacy) beside an unchanged terminal status and payment.paid; simulate stage round-trips.
class PaidLateTest < Minitest::Test
  EXPIRED = {
    'invoice_id' => 'inv_1',
    'project_id' => 'prj_1',
    'status' => 'expired',
    'is_final' => true,
    'is_test' => false,
    'payment_url' => 'https://pay.test/inv_1',
    'order' => { 'external_id' => 'order_1', 'amount' => '100.00', 'currency' => 'USD' },
    'payment' => {
      'currency' => 'USDT', 'network' => 'tron', 'chain_id' => 728_126_428,
      'expected' => '100.00', 'paid' => '60.00'
    },
    'created_at' => 1_700_000_000,
    'updated_at' => 1_700_003_600,
    'expires_at' => 1_700_003_600,
    'completed_at' => 1_700_003_600
  }.freeze

  def test_decodes_unix_mark_beside_terminal_status
    invoice = Paymos::Invoice.from(EXPIRED.merge('paid_late_at' => 1_700_007_200))
    assert_equal 'expired', invoice.status
    assert invoice.is_final
    assert_equal 1_700_007_200, invoice.paid_late_at
    assert_equal '60.00', invoice.payment.paid
  end

  def test_decodes_nil_and_absent_marks
    nil_marked = Paymos::Invoice.from(EXPIRED.merge('paid_late_at' => nil))
    assert_nil nil_marked.paid_late_at

    legacy = Paymos::Invoice.from(EXPIRED.dup)
    assert_nil legacy.paid_late_at
    assert_equal 'expired', legacy.status
  end

  def test_rejects_unknown_stage_and_accepts_paid_late
    client = Paymos::Client.new(api_key: 'pk', api_secret: 'sk')
    assert_raises(ArgumentError) { client.invoices.simulate_payment('inv_1', stage: 'explode') }

    request = Class.new do
      attr_reader :captured

      def initialize(payload_source)
        @payload_source = payload_source
      end

      def request(_method, _path, payload: nil, **_)
        @captured = payload
        @payload_source.call
      end
    end.new(-> { EXPIRED.dup })
    resource = Paymos::Invoices.new(request)
    resource.simulate_payment('inv_1', stage: 'paid_late')
    assert_equal({ stage: 'paid_late' }, request.captured)
  end
end
