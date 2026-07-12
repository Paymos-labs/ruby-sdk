# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paymos/version'

class ReleaseMetadataTest < Minitest::Test
  def test_lockfile_matches_runtime_version
    lockfile = File.read(File.expand_path('../Gemfile.lock', __dir__))

    assert_match(/^    paymos \(#{Regexp.escape(Paymos::VERSION)}\)\r?$/, lockfile)
  end
end
