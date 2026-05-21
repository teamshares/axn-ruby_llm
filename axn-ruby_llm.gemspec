# frozen_string_literal: true

require_relative "lib/axn/ruby_llm/version"

Gem::Specification.new do |spec|
  spec.name = "axn-ruby_llm"
  spec.version = Axn::RubyLLM::VERSION
  spec.authors = ["Kali Donovan"]
  spec.email = ["kali@teamshares.com"]

  spec.summary = "RubyLLM wrapper for Axn actions"
  spec.description = "Call LLMs from Axn actions using RubyLLM, with structured error handling, optional JSON mode, and OpenTelemetry tracing."
  spec.homepage = "https://github.com/teamshares/axn-ruby_llm"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ spec/ .git .github Gemfile Gemfile.lock .rspec_status pkg/ tmp/ .rspec .rubocop])
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "axn", ">= 0.1.0-alpha.4.2", "< 0.2.0"
  spec.add_dependency "ruby_llm", ">= 1.0", "< 2.0"
end
