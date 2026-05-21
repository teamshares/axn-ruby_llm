# Changelog

## [0.1.0] - 2026-05-21

Initial release.

- `Axn::RubyLLM::Ask` action — port of the `Actions::LLM::Ask` pattern from buyout-app, with parameterized model/system_prompt/temperature and opt-in JSON mode (default `false`).
- `Axn::RubyLLM.ask` / `ask!` module-level shortcuts.
- Structured output: pass `schema:` (a `RubyLLM::Schema` class, instance, or any JSON Schema hash) to enable provider-enforced structured output via `RubyLLM::Chat#with_schema`. Result returns a parsed Hash; non-JSON responses fail with `"Schema response was not valid JSON"`. Takes precedence over `json: true`.
- Result exposes `response`, `raw_message`, `input_tokens`, `output_tokens`, `cost` (Float USD total), and `cost_breakdown` (`RubyLLM::Cost` struct). Cost fields are nil when RubyLLM lacks pricing for the model.
- OpenTelemetry tracing via thoughtbot's [`opentelemetry-instrumentation-ruby_llm`](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm) (runtime dep). Auto-installed when `OpenTelemetry::SDK` is defined; control via `Axn::RubyLLM.configure { |c| c.opentelemetry = :auto | true | false }`. Spans use the standard `gen_ai.*` GenAI semantic conventions and cover direct `RubyLLM.chat` callers, tool calls, and embeddings.
- Production gating: `Axn::RubyLLM.configure { |c| c.enabled = -> { ... } }` (Boolean or callable). When disabled, `Ask` returns a success result with stub content (`response: "stubbed response value"` for plain, `{ "stubbed" => true }` for json/schema; `raw_message` is an `Ask::StubMessage` Data instance; tokens/cost zeroed) and `result.stubbed == true`.
- Rate-limit handling rescues `RubyLLM::RateLimitError` (HTTP 429, provider-agnostic) and fails with `"Rate limit reached: <message>"`.
- `Axn::RubyLLM::RSpec::Helpers` — `stub_axn_ruby_llm` helper accepting `response:`, optional `model:`, `schema:`, `input_tokens:`, `output_tokens:`, `cost:`.
