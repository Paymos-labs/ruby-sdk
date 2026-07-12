# frozen_string_literal: true

require 'rake/testtask'
require 'bundler/gem_tasks'

Rake::TestTask.new do |task|
  task.libs << 'lib'
  task.pattern = 'test/**/*_test.rb'
  task.warning = true
end

task :typecheck do
  sh 'bundle exec rbs validate'
end

task :lint do
  sh 'bundle exec rubocop'
end

task check: %i[test typecheck lint build]
task default: :check
