# frozen_string_literal: true

require 'paymos'

abort 'unexpected Paymos version' unless Paymos::VERSION == '1.0.0'
abort 'unexpected RFC3986 encoding' unless Paymos::Signing.path_segment('a b/*~') == 'a%20b%2F%2A~'
