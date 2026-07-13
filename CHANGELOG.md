# Changelog

## [Unreleased]

Adds `Axn::RubyLLM.wrap(any_axn)` (PRO-2845), a tool adapter turning any Axn into a `::RubyLLM::Tool` a chat can call — no adapter-specific mixin required. Name, description, and JSON Schema params are read straight off the Axn's own declared contract (`resolved_axn_name` / `description` / `input_schema`, from axn's core reflection, added alongside the parallel `Axn::MCP.wrap` groundwork in axn core PRO-2842). On success, `execute` returns the exposed values (`Axn::Reflection::Values.serialize_exposed`) as a JSON string; on failure, `{ error: result.error }`. See the README's "Tool adapter" section.

- The tool name is sanitized to `[a-zA-Z0-9_-]`, since providers require API-safe tool names and `resolved_axn_name` may be a free-form class name or the "Anonymous Axn" fallback.
- A call missing a required argument, or carrying one outside the advertised schema, short-circuits with RubyLLM's own `{ error: "Invalid tool arguments: ..." }` instead of invoking the Axn — `execute`'s `**args` signature otherwise bypasses `Tool#call`'s built-in keyword validation, which would let a malformed tool call reach Axn's dev-facing (exception-bucket, generic-message) input validation instead of a clean tool-level error.
- The unknown-argument check also closes a prompt-injection path: `ambient_context` is never advertised in the reflected schema, but nothing previously stopped a malicious/malformed tool call from supplying one anyway and having it silently override the caller's own ambient context inside `axn_class.call`.
- A `:structured` success payload is serialized to a JSON string rather than returned as a raw Hash — `RubyLLM::Chat#handle_tool_calls` only passes a `Content`/`Content::Raw` return through as-is, and otherwise sends `tool_payload.to_s`, which for a Hash produces Ruby's inspect syntax (`{"k"=>"v"}`) rather than valid JSON.
- `halt_after:` (wrap the success payload in `RubyLLM::Tool::Halt`), `provider_params:` (forwarded to `with_params`), and `render_as:` (`:structured` default vs `:text`, returning `result.message`) are declared as overridable settings under the `:ruby_llm` config namespace (axn's namespaced per-class config, PRO-2880/[axn#154](https://github.com/teamshares/axn/pull/154)) — settable per-call via a `wrap` keyword, once on the Axn via `configure(:ruby_llm) { |c| ... }` (no `include` required — every Axn gets `configure` for free), or gem-wide via `Axn::RubyLLM.configure { |c| ... }`, in that precedence order. Namespacing is what lets one base Axn be configured for both this gem and axn-mcp (or any other adapter) without their settings colliding, even on a shared name.
- `ambient_context:` closes the tool over explicit caller context instead of the reflective `Current` default (required across a `call_async` boundary, since ambient context doesn't cross it) and returns a tool instance rather than the class, since `chat.with_tool` accepts either.

Narrows the generic exception-message fallback in `Ask`'s error DSL and adds two more specific failure reasons:

- **The catch-all reason is now scoped to RubyLLM's known error classes** (`RubyLLM::Error` plus its non-HTTP errors — `ConfigurationError`, `ModelNotFoundError`, `PromptNotFoundError`, `InvalidRoleError`, `InvalidToolChoiceError`, `UnsupportedAttachmentError`, none of which subclass `RubyLLM::Error`) and `Faraday::Error` (network/transport failures, never wrapped by RubyLLM), instead of matching any `StandardError`. A genuinely unrecognized exception (most likely a bug in this gem, RubyLLM, or a dependency) now fails with the bare `"LLM request failed"` headline instead of leaking the raw exception message into a user-facing `result.error`. This does not affect bug reporting — `Axn.config.on_exception` fires independently of the `error` message DSL, so unrecognized exceptions are still reported.
- **New: `RubyLLM::OverloadedError` / `ServiceUnavailableError` / `ServerError`** (5xx, transient provider-side issues) now fail with `"LLM request failed: Provider temporarily unavailable, try again later: <message>"`, distinguishing them from non-retryable errors. `RubyLLM::RateLimitError` keeps its own distinct `"Rate limit reached: <message>"` wording (unchanged).
- **New: `RubyLLM::ContextLengthExceededError`** now fails with `"LLM request failed: Prompt exceeds the model's context window: <message>"` — the provider's own message (which includes the actual token counts) is preserved after the actionable prefix.

Adds a new `error_headline` setting (default `"LLM request failed"`) to `Axn::RubyLLM.configure`, so the base `result.error` prefix is overridable without subclassing `Ask`.

## [0.1.3] - 2026-06-26

Adopts Axn's `Configurable` DSL for gem configuration (requires the axn version that ships `Axn::Configurable`).

- Replace the hand-rolled `Configuration` class with `extend Axn::Configurable`, declaring `default_model` (default `"gpt-4o-mini"`) and `enabled` (default `true`, callable) as settings.
- **Rename** `Axn::RubyLLM.configuration` → `Axn::RubyLLM.config` and `Axn::RubyLLM.reset_configuration!` → `Axn::RubyLLM.reset_config!`, matching the DSL's standard surface. `Axn::RubyLLM.configure { |c| ... }` is unchanged.
- The old names are kept as **deprecated aliases** — they still work but emit a deprecation warning (`category: :deprecated`) and are scheduled for removal in the next minor version. See [DEPRECATIONS.md](DEPRECATIONS.md).

Also migrates the `Ask` error-message DSL to axn's new message-presentation semantics ([axn#109](https://github.com/teamshares/axn/pull/109), [#132](https://github.com/teamshares/axn/pull/132), [#134](https://github.com/teamshares/axn/pull/134)), which replaced per-message `prefix:` with a base `error`/`success` headline plus a `standalone:` attach flag. Requires the axn version that ships these.

- **`result.error` now carries a consistent `"LLM request failed: <reason>"` headline for every failure mode** (previously only unhandled exceptions were prefixed). Affected strings:
  - Rate limit: `"LLM request failed: Rate limit reached: <message>"`
  - Schema parse: `"LLM request failed: Schema response was not valid JSON"`
  - JSON parse: `"LLM request failed: Response was not valid JSON"` (reason reworded from `"Failed to parse JSON from LLM response"` so it joins the headline cleanly)
  - Unhandled exceptions: `"LLM request failed: <exception message>"` (unchanged)
- **`result.success` now carries a meaningful headline** instead of axn's generic `"Action completed successfully"`:
  - Normal calls: `"LLM request completed"`.
  - Production-gated (disabled) calls: `"LLM request completed (using stubbed values - actual LLM request disabled)"`.

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
