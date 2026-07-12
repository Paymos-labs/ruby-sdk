# frozen_string_literal: true

require 'json'
require 'openssl'
require 'time'

module Paymos
  class WebhookVerifier
    def initialize(secret, tolerance: 300, clock: -> { Time.now.to_i })
      unless secret.is_a?(String) && !secret.strip.empty?
        raise ArgumentError,
              'Webhook secret must be a non-empty string'
      end
      raise ArgumentError, 'Webhook tolerance must be non-negative' unless tolerance.is_a?(Integer) && tolerance >= 0

      @secret = secret
      @tolerance = tolerance
      @clock = clock
    end

    def verify(signature_header, raw_body, now: nil)
      assert_valid(signature_header, raw_body, now: now)
      true
    rescue SignatureMismatchError, TimestampSkewError
      false
    end

    def assert_valid(signature_header, raw_body, now: nil)
      raise ArgumentError, 'Raw webhook body must be a string' unless raw_body.is_a?(String)

      timestamp, signatures = parse_header(signature_header)
      current = now.nil? ? @clock.call.to_i : now.to_i
      if (current - timestamp).abs > @tolerance
        raise TimestampSkewError,
              'Webhook timestamp is outside the allowed tolerance'
      end

      expected = OpenSSL::HMAC.hexdigest('SHA256', @secret, "#{timestamp}.#{raw_body}")
      valid = signatures.any? { |value| secure_compare(expected, value.downcase) }
      raise SignatureMismatchError, 'Webhook signature does not match payload' unless valid

      nil
    end

    def construct_event(signature_header, raw_body, now: nil)
      assert_valid(signature_header, raw_body, now: now)
      WebhookEvent.from(JSON.parse(raw_body))
    rescue JSON::ParserError => e
      raise Error, "Webhook payload is invalid JSON: #{e.message}"
    end

    private

    def parse_header(header)
      timestamp = nil
      signatures = []
      header.to_s.split(',').each do |part|
        key, value = part.strip.split('=', 2)
        if key == 't'
          unless timestamp.nil? && value&.match?(/\A\d+\z/)
            raise SignatureMismatchError,
                  'Webhook signature header is missing or malformed'
          end

          timestamp = value.to_i
        end
        signatures << value if key == 'v1' && !value.to_s.empty?
      end
      if timestamp.nil? || signatures.empty?
        raise SignatureMismatchError,
              'Webhook signature header is missing or malformed'
      end

      [timestamp, signatures]
    end

    def secure_compare(expected, actual)
      return false unless expected.bytesize == actual.bytesize

      OpenSSL.fixed_length_secure_compare(expected, actual)
    end
  end
end
