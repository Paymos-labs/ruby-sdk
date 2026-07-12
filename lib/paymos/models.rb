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
    fields :invoice_id, :project_id, :status, :is_final, :is_test, :payment_url,
           :order, :payment, :created_at, :updated_at, :expires_at, :completed_at,
           required: %i[invoice_id project_id status is_final is_test payment_url order created_at updated_at]

    def self.from(value)
      model = super
      new(**model.to_h, order: Order.from(model.order), payment: model.payment && Payment.from(model.payment))
    end
  end

  class InvoiceListItem < Model
    fields :invoice_id, :project_id, :external_order_id, :client_id, :status,
           :is_final, :is_test, :amount, :currency, :network, :created_at,
           :expires_at, :completed_at,
           required: %i[invoice_id project_id external_order_id status is_final is_test amount currency created_at]
  end

  class Withdrawal < Model
    fields :withdrawal_id, :external_order_id, :status, :is_final, :is_test,
           :amount, :fee, :currency, :network, :destination_address, :tx_hash,
           :explorer_url, :created_at, :completed_at, :failed_at, :cancelled_at,
           required: %i[withdrawal_id external_order_id status is_final is_test amount currency
                        network destination_address created_at]
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
