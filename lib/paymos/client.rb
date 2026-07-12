# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'timeout'
require 'uri'

module Paymos
  Response = Struct.new(:status, :body, :headers, keyword_init: true) do
    def initialize(status:, body:, headers: {})
      super(status: Integer(status), body: String(body), headers: headers.to_h.transform_values do |value|
        String(value)
      end.freeze)
      freeze
    end
  end

  class Client
    SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

    attr_reader :invoices, :withdrawals, :balances, :system

    def initialize(api_key:, api_secret:, base_url: 'https://api.paymos.io', timeout: 30,
                   max_retries: 2, base_delay: 0.150, transport: nil,
                   clock: -> { Time.now.to_i }, sleeper: ->(seconds) { sleep(seconds) }, random: Random.new)
      raise ConfigurationError, 'api_key and api_secret are required' if api_key.to_s.empty? || api_secret.to_s.empty?
      unless timeout.positive? && max_retries >= 0 && base_delay >= 0
        raise ConfigurationError,
              'timeout, max_retries, and base_delay are invalid'
      end
      raise ConfigurationError, 'base_url is required' if base_url.to_s.strip.empty?

      @api_key = api_key
      @api_secret = api_secret
      origin = URI.parse(base_url)
      unless origin.absolute? && origin.host && [nil, '',
                                                 '/'].include?(origin.path) && origin.query.nil? && origin.fragment.nil?
        raise ConfigurationError, 'base_url must be an absolute origin without a path'
      end

      @base_url = base_url.delete_suffix('/')
      @timeout = timeout
      @max_retries = max_retries
      @base_delay = base_delay
      @transport = transport || method(:default_transport)
      @clock = clock
      @sleeper = sleeper
      @random = random
      @invoices = Invoices.new(self)
      @withdrawals = Withdrawals.new(self)
      @balances = Balances.new(self)
      @system = System.new(self)
    end

    def request(method, path, payload: nil, query: '')
      method = method.to_s.upcase
      body = payload.nil? ? '' : JSON.generate(payload)
      attempts = 0

      loop do
        begin
          timestamp = @clock.call.to_i.to_s
          headers = {
            'Authorization' => Signing.authorization(@api_key, @api_secret, timestamp, method, path, query, body),
            'X-Request-Timestamp' => timestamp,
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
            'User-Agent' => "paymos-ruby/#{VERSION}"
          }
          response = @transport.call(method, "#{@base_url}#{path}#{query}", headers, body.empty? ? nil : body, @timeout)
        rescue IOError, SystemCallError, Timeout::Error, SocketError => e
          if attempts < @max_retries && SAFE_METHODS.include?(method)
            wait(attempts, nil)
            attempts += 1
            next
          end
          raise Error, "Paymos request failed: #{e.message}", cause: e
        end

        unless response.respond_to?(:status) && response.respond_to?(:body) && response.respond_to?(:headers)
          raise Error, 'Paymos transport returned an invalid response'
        end

        if attempts < @max_retries && retryable?(method, response.status)
          wait(attempts, header(response.headers, 'retry-after'))
          attempts += 1
          next
        end

        unless (200..299).cover?(response.status)
          raise Paymos.api_error(response.status, response.body,
                                 response.headers)
        end
        raise Error, 'Paymos API returned an empty response' if response.body.to_s.empty?

        begin
          return JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise Error, "Paymos API returned invalid JSON: #{e.message}"
        end
      end
    end

    private

    def default_transport(method, url, headers, body, timeout)
      uri = URI(url)
      request_type = Net::HTTP.const_get(method.capitalize)
      request = request_type.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body unless body.nil?
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: timeout,
        read_timeout: timeout
      ) { |http| http.request(request) }
      Response.new(status: response.code.to_i, body: response.body.to_s,
                   headers: response.to_hash.transform_values(&:first))
    end

    def retryable?(method, status)
      status == 429 || (status >= 500 && SAFE_METHODS.include?(method))
    end

    def wait(attempt, retry_after)
      delay = (@base_delay * (2**attempt)) + (@random.rand * @base_delay)
      parsed_retry_after = retry_after_seconds(retry_after)
      delay = [delay, parsed_retry_after].max unless parsed_retry_after.nil?
      @sleeper.call(delay)
    end

    def retry_after_seconds(value)
      return nil if value.to_s.empty?
      return value.to_i if value.to_s.match?(/\A\d+\z/)

      [Time.httpdate(value.to_s).to_i - @clock.call.to_i, 0].max
    rescue ArgumentError
      nil
    end

    def header(headers, name)
      pair = headers.to_h.find { |key, _value| key.to_s.casecmp?(name) }
      pair&.last
    end
  end

  class Resource
    def initialize(client)
      @client = client
    end

    private

    def segment(value)
      raise ArgumentError, 'Resource ID is required' unless value.is_a?(String) && !value.strip.empty?

      Signing.path_segment(value)
    end

    def validate_reason(reason)
      unless reason.is_a?(String) && reason.length.between?(1, 500) && !reason.strip.empty?
        raise ArgumentError, 'Cancellation reason must contain 1 to 500 characters'
      end

      reason
    end

    def validate_list_filters(filters)
      limit = filters[:limit]
      unless limit.nil? || (limit.is_a?(Integer) && limit.between?(
        1, 100
      ))
        raise ArgumentError,
              'limit must be between 1 and 100'
      end
      raise ArgumentError, 'cursor cannot be empty' if filters.key?(:cursor) && filters[:cursor].to_s.empty?

      statuses = filters[:status]
      if statuses.is_a?(Array) && (statuses.empty? || statuses.uniq.length != statuses.length)
        raise ArgumentError, 'status must be non-empty and contain no duplicates'
      end

      from = filters[:created_from]
      to = filters[:created_to]
      unless [from, to].compact.all? { |value| value.is_a?(Integer) && value >= 0 }
        raise ArgumentError, 'created_from and created_to must be non-negative Unix seconds'
      end
      raise ArgumentError, 'created_to must be later than created_from' if from && to && from >= to

      filters
    end
  end

  class Invoices < Resource
    def create(project_id:, amount:, currency:, external_order_id:, network: nil,
               allow_multiple_payments: nil, customer_fee_percent: nil, client_id: nil)
      required_keywords(project_id:, amount:, currency:, external_order_id:)
      if !customer_fee_percent.nil? && !(customer_fee_percent.is_a?(Integer) && customer_fee_percent.between?(0, 100))
        raise ArgumentError, 'customer_fee_percent must be between 0 and 100'
      end

      payload = { project_id:, amount:, currency:, external_order_id:, network:,
                  allow_multiple_payments:, customer_fee_percent:, client_id: }.compact
      Invoice.from(@client.request('POST', '/v1/invoices', payload:))
    end

    def get(invoice_id) = Invoice.from(@client.request('GET', "/v1/invoices/#{segment(invoice_id)}"))

    def list(limit: nil, cursor: nil, status: nil, external_order_id: nil,
             project_id: nil, created_from: nil, created_to: nil)
      filters = validate_list_filters({ limit:, cursor:, status:, external_order_id:, project_id:, created_from:,
                                        created_to: }.compact)
      Page.from(@client.request('GET', '/v1/invoices', query: Signing.query(filters)), item_type: InvoiceListItem)
    end

    def cancel(invoice_id, reason:)
      Invoice.from(@client.request('POST', "/v1/invoices/#{segment(invoice_id)}/cancel",
                                   payload: { reason: validate_reason(reason) }))
    end

    def confirm_payment(invoice_id, currency:, network:)
      required_keywords(currency:, network:)
      Invoice.from(@client.request('POST', "/v1/invoices/#{segment(invoice_id)}/confirm-payment",
                                   payload: { currency:, network: }))
    end

    def simulate_payment(invoice_id, stage:)
      raise ArgumentError, 'Invalid simulation stage' unless %w[paid overpaid underpay cancel].include?(stage)

      Invoice.from(@client.request('POST', "/v1/sandbox/invoices/#{segment(invoice_id)}/simulate-payment",
                                   payload: { stage: }))
    end

    def each(max_pages: 100, **filters, &block)
      return enum_for(__method__, max_pages: max_pages, **filters) unless block_given?

      Pagination.each(method(:list), filters, max_pages:, &block)
    end

    private

    def required_keywords(**values)
      missing = values.select { |_name, value| !value.is_a?(String) || value.strip.empty? }.keys
      raise ArgumentError, "Required values are missing: #{missing.join(', ')}" unless missing.empty?
    end
  end

  class Withdrawals < Resource
    def create(destination_address:, network:, currency:, amount:, external_order_id:)
      values = { destination_address:, network:, currency:, amount:, external_order_id: }
      missing = values.select { |_name, value| !value.is_a?(String) || value.strip.empty? }.keys
      raise ArgumentError, "Required values are missing: #{missing.join(', ')}" unless missing.empty?

      Withdrawal.from(@client.request('POST', '/v1/withdrawals', payload: values))
    end

    def get(withdrawal_id) = Withdrawal.from(@client.request('GET', "/v1/withdrawals/#{segment(withdrawal_id)}"))

    def list(limit: nil, cursor: nil, status: nil, external_order_id: nil,
             created_from: nil, created_to: nil)
      filters = validate_list_filters({ limit:, cursor:, status:, external_order_id:, created_from:,
                                        created_to: }.compact)
      Page.from(@client.request('GET', '/v1/withdrawals', query: Signing.query(filters)), item_type: Withdrawal)
    end

    def cancel(withdrawal_id, reason:)
      Withdrawal.from(@client.request('POST', "/v1/withdrawals/#{segment(withdrawal_id)}/cancel",
                                      payload: { reason: validate_reason(reason) }))
    end

    def simulate_completion(withdrawal_id)
      Withdrawal.from(@client.request('POST', "/v1/sandbox/withdrawals/#{segment(withdrawal_id)}/simulate-completion"))
    end

    def each(max_pages: 100, **filters, &block)
      return enum_for(__method__, max_pages: max_pages, **filters) unless block_given?

      Pagination.each(method(:list), filters, max_pages:, &block)
    end
  end

  class Balances < Resource
    def get = Array(@client.request('GET', '/v1/balances')).map { |item| Balance.from(item) }.freeze
  end

  class System < Resource
    def time = ServerTime.from(@client.request('GET', '/v1/time'))
  end

  module Pagination
    module_function

    def each(fetch, filters, max_pages: 100, &block)
      raise ArgumentError, 'max_pages must be a positive integer' unless max_pages.is_a?(Integer) && max_pages.positive?

      filters = filters.dup
      cursor = filters[:cursor]
      max_pages.times do
        page = fetch.call(**filters)
        page.items.each(&block)
        next_cursor = page.next_cursor
        return if next_cursor.nil? || next_cursor.to_s.empty?
        raise Error, 'Paymos API returned the same pagination cursor twice' if next_cursor == cursor

        cursor = next_cursor
        filters[:cursor] = cursor
      end
    end
  end
end
