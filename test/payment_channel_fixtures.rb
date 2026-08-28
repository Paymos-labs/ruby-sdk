# frozen_string_literal: true

require 'json'

# Wire-shaped payment-channel fixtures, shared by the route matrix and the payment-channel suite.
# Money is a string, timestamps are Unix seconds as numbers, and the optional members
# (contract_address, source_address, first_included_block_timestamp, explorer_url, confirmed_at) are
# simply absent rather than null — the API omits nulls.
module PaymentChannelFixtures
  module_function

  def payment_channel(id: 'pc_1', is_accepting_payments: true)
    {
      id:, project_id: 'prj_1', external_id: 'customer-42', status: 'active',
      is_accepting_payments:, is_fully_provisioned: true, is_test: true,
      applied_fee_percent: 1.5, customer_fee_percent: 0,
      networks: [{ network: 'TRC20', status: 'active', address: 'TXaddress',
                   tokens: [{ symbol: 'USDT', minimum_deposit: '1.00' }] }],
      created_at: 1_700_000_000, updated_at: 1_700_000_000
    }
  end

  def payment_channel_deposit(id: 'pcd_1')
    {
      id:, payment_channel_id: 'pc_1', project_id: 'prj_1', payment_channel_external_id: 'customer-42',
      status: 'confirmed', is_final: true, is_test: true, currency: 'USDT', network: 'TRC20',
      chain_id: 728_126_428, gross: '100.00', fee: '1.50', net: '98.50',
      applied_fee_percent: 1.5, customer_fee_percent: 0, tx_hash: 'abc123', transfer_id: 'tr_1',
      destination_address: 'TXaddress', block_height: 42,
      created_at: 1_700_000_000, updated_at: 1_700_000_000, confirmed_at: 1_700_000_000
    }
  end

  def payment_channel_json(**overrides) = JSON.generate(payment_channel(**overrides))

  def payment_channel_deposit_json(**overrides) = JSON.generate(payment_channel_deposit(**overrides))
end
