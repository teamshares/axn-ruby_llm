# Changelog

## [0.1.0] - 2026-05-19

Initial release.

- `Axn::RubyLLM::Actions::Ask` — port of the `Actions::LLM::Ask` pattern from buyout-app, with parameterized model/system_prompt/temperature, opt-in JSON mode (default `false`), configurable rate-limit phrase, and OpenTelemetry tracing.
- `Axn::RubyLLM::RSpec::Helpers` — `stub_axn_ruby_llm` helper for specs.
