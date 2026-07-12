# frozen_string_literal: true

require 'json'
require 'time'

module Paymos
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class SignatureMismatchError < Error; end
  class TimestampSkewError < Error; end

  class ApiError < Error
    attr_reader :status, :body, :headers, :problem

    def initialize(status, body, headers = {})
      @status = status
      @body = body.to_s
      @headers = headers.to_h.transform_keys { |key| key.to_s.downcase }
      @problem = parse_problem(@body)
      super("Paymos API #{status}: #{detail}")
    end

    def errors
      value = problem.is_a?(Hash) ? problem['errors'] : nil
      value.is_a?(Array) ? value : []
    end

    def code
      first = errors.first
      value = first.is_a?(Hash) ? first['code'] : problem&.fetch('code', nil)
      value.to_s
    end

    def field
      first = errors.first
      first.is_a?(Hash) ? first['field'] : problem&.fetch('field', nil)
    end

    def detail
      value = problem&.fetch('detail', nil)
      first = errors.first
      value ||= first['message'] if first.is_a?(Hash)
      value ||= code unless code.empty?
      value ||= problem&.fetch('title', nil)
      value ||= body unless body.empty?
      value || 'empty response'
    end

    def retry_after_seconds(now: Time.now)
      value = headers['retry-after']
      return nil if value.nil? || value.empty?
      return value.to_i if value.match?(/\A\d+\z/)

      [(Time.httpdate(value) - now).ceil, 0].max
    rescue ArgumentError
      nil
    end

    private

    def parse_problem(value)
      parsed = value.empty? ? nil : JSON.parse(value)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end

  class ValidationError < ApiError; end
  class AuthenticationError < ApiError; end
  class NotFoundError < ApiError; end
  class ConflictError < ApiError; end
  class GoneError < ApiError; end
  class RateLimitError < ApiError; end
  class ServerError < ApiError; end
  class UnavailableError < ServerError; end

  ERROR_TYPES = {
    400 => ValidationError,
    401 => AuthenticationError,
    403 => AuthenticationError,
    404 => NotFoundError,
    409 => ConflictError,
    410 => GoneError,
    429 => RateLimitError,
    503 => UnavailableError
  }.freeze

  def self.api_error(status, body, headers = {})
    type = ERROR_TYPES.fetch(status, status >= 500 ? ServerError : ApiError)
    type.new(status, body, headers)
  end
end
