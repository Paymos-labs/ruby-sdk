# frozen_string_literal: true

require 'minitest/autorun'
require 'rubygems'
require_relative '../lib/paymos'

class ReleaseMetadataTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  RBS = File.read(File.join(ROOT, 'sig/paymos.rbs'))

  def test_lockfile_matches_runtime_version
    lockfile = File.read(File.expand_path('../Gemfile.lock', __dir__))

    assert_match(/^    paymos \(#{Regexp.escape(Paymos::VERSION)}\)\r?$/, lockfile)
  end

  # The README points at conformance/contract.json, so the gem must ship it.
  def test_package_manifest_includes_conformance_contract
    spec = Dir.chdir(ROOT) { Gem::Specification.load('paymos.gemspec') }

    assert_includes spec.files, 'conformance/contract.json'
  end

  # The published RBS must declare every public model reader, status constant and error class
  # the runtime defines; `rbs validate` only checks the declarations that exist.
  def test_public_rbs_covers_runtime_models_statuses_and_errors
    model_classes.each do |model|
      readers = rbs_block("class #{short_name(model)}").scan(/attr_reader (\w+):/).flatten
      missing = model.field_names.map(&:to_s) - readers

      assert_empty missing, "sig/paymos.rbs #{short_name(model)} lacks readers: #{missing.join(', ')}"
    end

    [Paymos::InvoiceStatus, Paymos::WithdrawalStatus, Paymos::RefundMode].each do |mod|
      block = rbs_block("module #{short_name(mod)}")
      mod.constants.each do |name|
        assert_includes block, "#{name}: \"#{mod.const_get(name)}\"", "sig/paymos.rbs #{mod} lacks #{name}"
      end
    end

    error_classes.each do |error|
      declaration = "class #{short_name(error)} < #{short_name(error.superclass)}"

      assert_includes RBS, declaration, "sig/paymos.rbs lacks #{declaration}"
    end
  end

  def test_public_rbs_declares_permission_error_and_paid_late_at
    assert_includes RBS, 'class PermissionError < AuthenticationError'
    assert_includes rbs_block('class Invoice'), 'attr_reader paid_late_at: Integer?'
    assert_includes rbs_block('class InvoiceListItem'), 'attr_reader paid_late_at: Integer?'
  end

  private

  def model_classes
    paymos_classes.select { |value| value < Paymos::Model && value.field_names }
  end

  def error_classes
    paymos_classes.select { |value| value < Paymos::Error }
  end

  def paymos_classes
    Paymos.constants.map { |name| Paymos.const_get(name) }.grep(Class)
  end

  def short_name(constant)
    constant.name.split('::').last
  end

  # The text of one top-level declaration in the RBS, from its header to its matching `end`.
  def rbs_block(header)
    match = RBS.match(/^  #{Regexp.escape(header)}(?:\[\w+\])?(?: < [\w:]+)?\n(.*?)^  end$/m)
    flunk "sig/paymos.rbs has no `#{header}`" unless match
    match[1]
  end
end
