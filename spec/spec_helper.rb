# frozen_string_literal: true

require "bundler/setup"
Bundler.require(:default, :development)

require "axn-ruby_llm"
require "axn/testing/spec_helpers"
require "axn/ruby_llm/rspec"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.after do
    Axn::RubyLLM.reset_configuration!
  end
end
