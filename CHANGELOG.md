# Changelog

## [Unreleased]

> **Upgrade notes (behavior changes):**
> - **`Ask` failure messages changed wording.** Code that pattern-matches on `result.error` strings may need updating: unrecognized exceptions no longer include the underlying exception message, and 5xx / context-length errors now have their own more specific text (see Changed below). `result.ok?`-based control flow is unaffected.
> - **Requires a newer `axn`** — this release depends on core reflection, the tool registry + `tool_name`, and namespaced `configure(...)` (see Requires below).
> - No public API was removed, and no config or `wrap` option changed name or default.

### Added

- **Tool adapter — wrap any Axn as a `RubyLLM::Tool`.** `Axn::RubyLLM.wrap(any_axn)` turns any Axn into a `::RubyLLM::Tool` a chat can call, with no adapter-specific mixin: its name, description, and JSON Schema parameters come from the Axn's own `description`/`expects`/`exposes` contract. On success the tool returns the exposed values as JSON (or `result.message`, per `present_as:`); on failure, `{ error: <result.error> }`. Malformed tool calls — a missing/unknown/wrong-typed argument, a value outside an `inclusion` set (validated at full depth via axn's tool `Invoker`), or an injected `ambient_context:` — come back to the model as a clean `Invalid tool arguments` error and never page `on_exception`. A result core can't serialize (two Hash keys colliding on one JSON property, a non-finite Float, non-UTF-8 bytes) or one nested past the JSON encoder's `max_nesting` likewise surfaces as a tool error instead of breaking the chat. Per-tool options `halt_after:`, `provider_params:`, `present_as:` (`:structured` / `:message`), and `ambient_context:` are settable per-call, per-class via `configure(:ruby_llm) { |c| ... }` (or inline via `tool ruby_llm: { ... }`), or gem-wide via `Axn::RubyLLM.configure`. The same Axn advertises an identical tool name whether wrapped here or by `Axn::MCP.wrap`. See the README's "Tool adapter" section.
- **Tools in `ask`.** `Axn::RubyLLM.ask(prompt:, tools: [...])` registers wrapped Axns on the chat and runs RubyLLM's tool-call loop within the single call. `tools:` takes bare Axn classes (wrapped automatically) and already-wrapped tools alike, or pass `Axn::RubyLLM.tools` for everything registered. Token counts, `cost`, and `cost_breakdown` are summed across every turn of the loop (not just the final response; `raw_message` remains the final response).
- **Tool registry integration.** `Axn::RubyLLM.tools` returns every Axn registered under the `:ruby_llm` adapter — one whose file lives under the adapter's `tool_roots` (default `["agent_tools"]`), or that declares `tool` / `tool :ruby_llm`, or that carries a `configure(:ruby_llm)` bag, minus any `tool false` / `tool except: :ruby_llm` opt-outs — each wrapped and ready to register in stable, `tool_name`-sorted order: `chat.with_tools(*Axn::RubyLLM.tools)`. When tools declare `tool_version`, only the latest version per `tool_name` is returned. Configure the directories via `Axn::RubyLLM.configure { |c| c.tool_roots = [...] }`.
- **`error_headline` config** (default `"LLM request failed"`) overrides the prefix on every `Ask` failure without subclassing.
- **`reject_opaque_exposed_values` config** (default `false`; per-tool via `configure(:ruby_llm)`, per-class wins). When `true`, a tool result holding a value with no author-declared JSON form — one that would otherwise ship as an opaque blob (`"#<User:0x…>"`, or an ActiveSupport instance-variable dump under Rails) — fails as a tool error instead. Output-side only; the always-on rejections (reference cycles, non-finite Floats, non-UTF-8 bytes, colliding JSON keys) are unaffected. Mirrors axn-mcp's knob; built on `serialize_exposed(reject_opaque:)` from axn [#206](https://github.com/teamshares/axn/pull/206) (PRO-2988).

### Changed

- **`Ask` failures now carry a consistent `"LLM request failed: <reason>"` message, with more specific reasons.** Rate limits, transient provider errors (5xx → "Provider temporarily unavailable, try again later"), context-length-exceeded, and invalid-JSON responses each get their own wording; the provider's own message is preserved where useful. Unrecognized exceptions (likely bugs, not known RubyLLM/network failures) now fail with the bare headline and no leaked exception detail — error reporting via `Axn.config.on_exception` is unaffected. See the README's "Errors" section.
- **OpenTelemetry attribute recording is guarded by axn's `Extensions.best_effort` helper** — a telemetry failure now warn-logs (and fails loud in development) instead of vanishing silently, while still never breaking the LLM call.
- **Production gating: read the resolved gate via `Axn::RubyLLM.enabled?`.** axn's `Configurable` dropped its `callable:` kwarg (axn [#209](https://github.com/teamshares/axn/pull/209) / PRO-3017), so it no longer invokes an assigned `enabled` callable on read. Callable resolution moved into this gem — `Axn::RubyLLM.enabled?` invokes the callable and returns a Boolean, and is the supported reader. The DSL-generated `Axn::RubyLLM.config.enabled?` returns an assigned Proc as-is (always truthy) and must not be used for the gate.

### Requires

- An `axn` version providing core contract reflection, the tool registry (per-adapter `tool_roots` + union membership) with canonical `tool_name`, the tool `Invoker` (input-validation surfacing), the extension-author surface (`Axn::Extensions.best_effort` and the `Axn::Extensions::Serialization.render` result serializer — axn [#207](https://github.com/teamshares/axn/pull/207) / PRO-2992, which made `Axn::Reflection::Values.serialize_exposed` private), and namespaced per-class `configure(...)`. Satisfied by the released `axn` `0.1.0-alpha.5`, resolved from RubyGems (the gemspec pins `>= 0.1.0-alpha.5, < 0.2.0`).

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
