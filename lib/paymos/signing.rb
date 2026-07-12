# frozen_string_literal: true

require 'base64'
require 'digest'
require 'openssl'

module Paymos
  module Signing
    module_function

    def string_to_sign(timestamp, method, path, query = '', body = '')
      body_hash = body.empty? ? '' : Digest::SHA256.hexdigest(body.encode(Encoding::UTF_8))
      [timestamp, method.to_s.upcase, path, query, body_hash].join("\n")
    end

    def sign(secret, value)
      Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, value))
    end

    def authorization(api_key, api_secret, timestamp, method, path, query = '', body = '')
      signature = sign(api_secret, string_to_sign(timestamp, method, path, query, body))
      "HMAC-SHA256 #{api_key}:#{signature}"
    end

    def path_segment(value)
      percent_encode(value)
    end

    def query(filters)
      parts = filters.keys.sort_by(&:to_s).flat_map do |key|
        raw = filters[key]
        next [] if raw.nil?

        values = raw.is_a?(Array) ? raw.sort_by(&:to_s) : [raw]
        raise ArgumentError, "Paymos list filter cannot be empty: #{key}" if values.empty?

        values.map do |value|
          raise ArgumentError, "Invalid Paymos list filter: #{key}" unless value.is_a?(String) || value.is_a?(Integer)
          raise ArgumentError, "Invalid Paymos list filter: #{key}" if value.to_s.empty?

          "#{percent_encode(key)}=#{percent_encode(value)}"
        end
      end
      parts.empty? ? '' : "?#{parts.join('&')}"
    end

    def percent_encode(value)
      value.to_s.encode(Encoding::UTF_8).bytes.map do |byte|
        character = byte.chr
        character.match?(/[A-Za-z0-9._~-]/) ? character : format('%%%02X', byte)
      end.join
    end
  end
end
