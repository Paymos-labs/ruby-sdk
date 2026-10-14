# frozen_string_literal: true

module Paymos
  module InvoiceStatus
    AWAITING_CLIENT = 'awaiting_client'
    AWAITING_PAYMENT = 'awaiting_payment'
    CONFIRMING = 'confirming'
    UNDERPAID_WAITING = 'underpaid_waiting'
    PAID = 'paid'
    PAID_OVER = 'paid_over'
    UNDERPAID = 'underpaid'
    EXPIRED = 'expired'
    CANCELLED = 'cancelled'
  end

  module WithdrawalStatus
    CREATED = 'created'
    PENDING_REVIEW = 'pending_review'
    SIGNED = 'signed'
    CANCELLING = 'cancelling'
    COMPLETED = 'completed'
    FAILED = 'failed'
    CANCELLED = 'cancelled'
  end

  class Model
    class << self
      attr_reader :field_names, :required_names

      def fields(*names, required: names)
        @field_names = names.freeze
        @required_names = required.freeze
        attr_reader(*names)
      end

      def from(value)
        raise Error, 'Paymos API response must be a JSON object' unless value.is_a?(Hash)

        attributes = field_names.to_h { |name| [name, value[name.to_s]] }
        missing = required_names.select { |name| attributes[name].nil? }
        raise Error, "Paymos API response is missing: #{missing.join(', ')}" unless missing.empty?

        new(**attributes)
      end
    end

    def initialize(**attributes)
      unknown = attributes.keys - self.class.field_names
      raise ArgumentError, "Unknown model fields: #{unknown.join(', ')}" unless unknown.empty?

      self.class.field_names.each do |name|
        instance_variable_set("@#{name}", Model.deep_freeze(attributes[name]))
      end
      freeze
    end

    def [](name)
      public_send(name.to_sym)
    end

    def to_h
      self.class.field_names.to_h { |name| [name, public_send(name)] }
    end

    def self.deep_freeze(value)
      case value
      when Hash
        value.transform_values { |item| deep_freeze(item) }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      else
        value.freeze
      end
    end
  end

  class Order < Model
    fields :external_id, :client_id, :amount, :currency, :network,
           required: %i[external_id amount currency]
  end

  class Transfer < Model
    fields :tx_hash, :amount, :status, :created_at, :confirmed_at,
           :required_confirmations, :estimated_confirmation_at, :explorer_url,
           required: %i[tx_hash amount status created_at]
  end

  class Payment < Model
    fields :currency, :network, :chain_id, :contract_address, :expected, :address,
           :exchange_rate, :paid, :remaining, :fee, :net, :transfers,
           required: %i[currency network chain_id expected]

    def self.from(value)
      model = super
      transfers = model.transfers&.map { |item| Transfer.from(item) }
      new(**model.to_h, transfers: transfers)
    end
  end

  class Invoice < Model
    # paid_late_at: invoice-late-payment — money crossed the invoice's total after it had already
    # closed as expired/underpaid. Unix seconds; nil while there is no late mark (field omitted).
    # status keeps its terminal meaning; the marker travels beside it.
    fields :invoice_id, :project_id, :status, :is_final, :is_test, :payment_url,
           :order, :payment, :created_at, :updated_at, :expires_at, :completed_at, :paid_late_at,
           required: %i[invoice_id project_id status is_final is_test payment_url order created_at updated_at]

    def self.from(value)
      model = super
      new(**model.to_h, order: Order.from(model.order), payment: model.payment && Payment.from(model.payment))
    end
  end

  class InvoiceListItem < Model
    # paid_late_at: invoice-late-payment additive late mark, Unix seconds; nil while there is no mark (field omitted).
    fields :invoice_id, :project_id, :external_order_id, :client_id, :status,
           :is_final, :is_test, :amount, :currency, :network, :created_at,
           :expires_at, :completed_at, :paid_late_at,
           required: %i[invoice_id project_id external_order_id status is_final is_test amount currency created_at]
  end

  class Withdrawal < Model
    fields :withdrawal_id, :external_order_id, :status, :is_final, :is_test,
           :amount, :fee, :currency, :network, :destination_address, :tx_hash,
           :explorer_url, :created_at, :completed_at, :failed_at, :cancelled_at,
           required: %i[withdrawal_id external_order_id status is_final is_test amount currency
                        network destination_address created_at]
  end

  # One accepted token on one rail. A missing minimum_deposit means the rail cannot be quoted right
  # now — it never means the token has no minimum.
  class PaymentChannelToken < Model
    fields :symbol, :minimum_deposit, required: %i[symbol]
  end

  # One rail of a channel. The address is absent until that rail provisions, and never changes after.
  class PaymentChannelNetwork < Model
    fields :network, :status, :address, :tokens, required: %i[network status tokens]

    def self.from(value)
      model = super
      new(**model.to_h, tokens: model.tokens.map { |item| PaymentChannelToken.from(item) })
    end
  end

  class PaymentChannel < Model
    fields :id, :project_id, :external_id, :status, :is_accepting_payments, :is_fully_provisioned,
           :is_test, :applied_fee_percent, :customer_fee_percent, :networks, :created_at, :updated_at,
           required: %i[id project_id external_id status is_accepting_payments is_fully_provisioned
                        is_test applied_fee_percent customer_fee_percent networks created_at updated_at]

    def self.from(value)
      model = super
      new(**model.to_h, networks: model.networks.map { |item| PaymentChannelNetwork.from(item) })
    end
  end

  # Doubles as the `data` payload of every payment_channel.deposit.* webhook event (decoded via
  # WebhookVerifier#construct_event, then PaymentChannelDeposit.from(event.data)). `confirming` and
  # `reorged` are ADVISORY and may arrive out of order — a `confirming` can land after the
  # `confirmed` for the same deposit, and a `reorged` can be superseded by a later `confirmed`.
  # Credit only on payment_channel.deposit.confirmed with is_final true, and never let an advisory
  # event regress a deposit already known to be confirmed: crediting on `confirming` releases goods
  # against money a reorg can still take back.
  class PaymentChannelDeposit < Model
    fields :id, :payment_channel_id, :project_id, :payment_channel_external_id, :status, :is_final,
           :is_test, :currency, :network, :chain_id, :contract_address, :gross, :fee, :net,
           :applied_fee_percent, :customer_fee_percent, :tx_hash, :transfer_id, :source_address,
           :destination_address, :block_height, :first_included_block_timestamp, :explorer_url,
           :created_at, :updated_at, :confirmed_at,
           required: %i[id payment_channel_id project_id payment_channel_external_id status is_final
                        is_test currency network chain_id gross fee net applied_fee_percent
                        customer_fee_percent tx_hash transfer_id destination_address block_height
                        created_at updated_at]
  end

  # The one feed position that could not be rendered, and why. Without it a stuck feed is
  # byte-identical to a quiet day, and a merchant cannot tell "no new payments" from "I am not
  # seeing my money". Reasons: booked_auth_missing, inconsistent, deposit_missing, channel_missing,
  # transfer_missing, not_confirmed.
  class PaymentChannelDepositFeedBlockage < Model
    fields :deposit_id, :reason
  end

  # One page of the confirmed-deposit feed. Deliberately NOT a Page: next_cursor is required here,
  # because the feed has no last page. An empty page still hands back a cursor past the global
  # publication positions this merchant's filter skipped, so store it and resume from it — never
  # stop polling because a page came back empty.
  class PaymentChannelDepositFeedPage < Model
    fields :items, :next_cursor, :blocked, required: %i[items next_cursor]

    def self.from(value)
      model = super
      raise Error, 'Paymos API page items must be an array' unless model.items.is_a?(Array)

      cursor = model.next_cursor
      raise Error, 'Paymos deposit feed page is missing a cursor' unless cursor.is_a?(String) && !cursor.empty?

      new(items: model.items.map { |item| PaymentChannelDeposit.from(item) }, next_cursor: cursor,
          blocked: model.blocked && PaymentChannelDepositFeedBlockage.from(model.blocked))
    end
  end

  class Balance < Model
    fields :currency, :available
  end

  class ServerTime < Model
    fields :server_time
  end

  class Page < Model
    fields :items, :next_cursor, required: [:items]

    def self.from(value, item_type:)
      model = super(value)
      raise Error, 'Paymos API page items must be an array' unless model.items.is_a?(Array)

      new(items: model.items.map { |item| item_type.from(item) }, next_cursor: model.next_cursor)
    end
  end

  class WebhookEvent < Model
    fields :event_id, :event_type, :version, :occurred_at, :data

    def self.from(value)
      model = super
      valid = model.event_id.is_a?(String) && !model.event_id.empty? &&
              model.event_type.is_a?(String) && !model.event_type.empty? &&
              model.version.is_a?(Integer) && model.version.positive? &&
              model.occurred_at.is_a?(Integer) && model.occurred_at >= 0 &&
              model.data.is_a?(Hash)
      raise Error, 'Webhook event envelope is invalid' unless valid

      model
    end
  end
end
