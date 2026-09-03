# frozen_string_literal: true

require_relative "lib/axn/ruby_llm/version"

Gem::Specification.new do |spec|
  spec.name = "axn-ruby_llm"
  spec.version = Axn::RubyLLM::VERSION
  spec.authors = ["Kali Donovan"]
  spec.email = ["kali@teamshares.com"]

  spec.summary = "RubyLLM wrapper for Axn actions"
  spec.description = "Call LLMs from Axn actions using RubyLLM, with structured error handling, optional JSON mode, and cost/token tracking."
  spec.homepage = "https://github.com/teamshares/axn-ruby_llm"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Allowlist, not denylist: enumerate exactly the shippable surface so nothing leaks into the
  # packaged gem by default (dev/CI/agent files, lefthook, internal-docs, etc. are simply not listed).
  spec.files = IO.popen(
    %w[git ls-files -z --
       lib README.md CHANGELOG.md LICENSE],
    chdir: __dir__, err: IO::NULL,
  ) { |ls| ls.readlines("\x0", chomp: true) }
  spec.require_paths = ["lib"]

  # PRO-2996: requires `Axn::Tools::AdapterSerialization` (`tool_roots_default`,
  # `declare_reject_opaque_exposed_values!`, `serialize_exposed`, `guard_tool_response`) and
  # `Axn::Extensions::Tracing.annotate_span` (PRO-3278) -- both released in 0.1.0-alpha.6.
  spec.add_dependency "axn", ">= 0.1.0-alpha.6", "< 0.2.0"
  spec.add_dependency "ruby_llm", ">= 1.15", "< 2.0"
end
