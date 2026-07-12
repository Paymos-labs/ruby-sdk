# frozen_string_literal: true

require_relative 'lib/paymos/version'

Gem::Specification.new do |spec|
  spec.name = 'paymos'
  spec.version = Paymos::VERSION
  spec.authors = ['Paymos Labs']
  spec.email = ['support@paymos.io']
  spec.summary = 'Official Ruby SDK for the Paymos Merchant API'
  spec.description = 'HMAC-authenticated client for invoices, withdrawals, balances, and webhooks.'
  spec.homepage = 'https://paymos.io/docs/server-sdks'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'
  spec.files = Dir['lib/**/*.rb', 'sig/**/*.rbs', 'README.md', 'CHANGELOG.md', 'LICENSE']
  spec.require_paths = ['lib']
  spec.add_dependency 'base64', '~> 0.3'
  spec.metadata = {
    'source_code_uri' => 'https://github.com/Paymos-labs/ruby-sdk',
    'changelog_uri' => 'https://github.com/Paymos-labs/ruby-sdk/blob/main/CHANGELOG.md',
    'documentation_uri' => 'https://paymos.io/docs/server-sdks',
    'homepage_uri' => 'https://paymos.io/docs/server-sdks',
    'rubygems_mfa_required' => 'true'
  }
end
