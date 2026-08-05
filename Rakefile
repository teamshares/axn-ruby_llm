# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new

task default: %i[spec rubocop]

# Gate `rake release` on the full test suite. bundler/gem_tasks' `release` depends on `build`, so
# enhancing `build` with `default` (spec + rubocop) runs the checks before the gem is built and
# pushed — a failing spec or RuboCop offense aborts the release before any push. Same mechanism as
# axn core, which enhances `build` with its broader `verify` task.
Rake::Task["build"].enhance([:default])
