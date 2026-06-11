# Changelog

## [0.1.2] - 2026-06-11

Requires RubyLLM >= 1.15 (minimum version bumped from 1.0).

RubyLLM 1.15 normalized token accounting: `input_tokens` now means non-cached input tokens only; cache activity is split into `cache_read_tokens` and `cache_write_tokens`. This release surfaces those fields and adds a convenience total.

- Add `cache_read_tokens` and `cache_write_tokens` exposures to `Ask`.
- Add `prompt_tokens` exposure — the sum of all three input token fields (`input_tokens + cache_read_tokens + cache_write_tokens`), matching OpenAI's `prompt_tokens` convention. Nil only if all three components are nil.
- Update `stub_axn_ruby_llm` helper to accept `cache_read_tokens:` and `cache_write_tokens:` params.
- Update `StubMessage` Data struct to include the new token fields (all zeroed in stub/disabled mode).

## [0.1.1] - 2026-06-11

- Use `mount_axn` pattern for `Axn::RubyLLM.ask` / `.ask!` / `.ask_async` shortcuts (via `Axn::Mountable`), replacing hand-written delegation. Requires axn `>= 0.1.0-alpha.4.3`.

## [0.1.0] - 2026-05-21

Initial release.

- `Axn::RubyLLM::Ask` action — port of the `Actions::LLM::Ask` pattern from buyout-app, with parameterized model/system_prompt/temperature and opt-in JSON mode (default `false`).
- `Axn::RubyLLM.ask` / `ask!` module-level shortcuts.
- Structured output: pass `schema:` (a `RubyLLM::Schema` class, instance, or any JSON Schema hash) to enable provider-enforced structured output via `RubyLLM::Chat#with_schema`. Result returns a parsed Hash; non-JSON responses fail with `"Schema response was not valid JSON"`. Takes precedence over `json: true`.
- Result exposes `response`, `raw_message`, `input_tokens`, `output_tokens`, `cost` (Float USD total), and `cost_breakdown` (`RubyLLM::Cost` struct). Cost fields are nil when RubyLLM lacks pricing for the model.
- OpenTelemetry span enrichment: when an OTel SDK is loaded, every `Ask` call sets `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cost` (USD), and `axn.ruby_llm.stubbed` on the existing `axn.call` span. No configuration required; no-op if OTel is not loaded. Full LLM-level tracing (individual chat calls, tool calls, embeddings) requires [`opentelemetry-instrumentation-ruby_llm`](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm) in your own Gemfile.
- Production gating: `Axn::RubyLLM.configure { |c| c.enabled = -> { ... } }` (Boolean or callable). When disabled, `Ask` returns a success result with stub content (`response: "stubbed response value"` for plain, `{ "stubbed" => true }` for json/schema; `raw_message` is an `Ask::StubMessage` Data instance; tokens/cost zeroed) and `result.stubbed == true`.
- Rate-limit handling rescues `RubyLLM::RateLimitError` (HTTP 429, provider-agnostic) and fails with `"Rate limit reached: <message>"`.
- `Axn::RubyLLM::RSpec::Helpers` — `stub_axn_ruby_llm` helper accepting `response:`, optional `model:`, `schema:`, `input_tokens:`, `output_tokens:`, `cost:`.
