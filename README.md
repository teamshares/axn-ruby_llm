# axn-ruby_llm

Call LLMs from [Axn](https://github.com/teamshares/axn) actions using [RubyLLM](https://github.com/crmne/ruby_llm), with declarative error handling, optional JSON mode, configurable defaults, and cost/token tracking — and wrap any Axn as a `RubyLLM::Tool` a chat can call.

Part of the `axn-*` extension ecosystem — see also [axn-mcp](https://github.com/teamshares/axn-mcp).

### Why use this over calling RubyLLM directly?

Four things you'd otherwise hand-build:

1. **Structured error handling.** The Axn error DSL declaratively maps `RateLimitError`, `JSON::ParserError`, and generic `StandardError` to clean failure messages. Callers check `result.ok?` instead of wrapping every call in `begin/rescue`.

2. **Production gating.** A single `c.enabled = -> { Rails.env.production? }` in an initializer stubs every LLM call in non-prod environments — no per-callsite guards needed. The stub is typed (`stubbed: true`, `input_tokens: 0`, etc.) so downstream code doesn't need to branch on it either.

3. **Cost/token tracking, exposed automatically.** Every call exposes `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `prompt_tokens` (the total), `cost`, and `cost_breakdown` without you doing the `RubyLLM.models.find` lookup manually. If your app uses OpenTelemetry, these values are also set as attributes on the existing `axn.call` span — no configuration required.

4. **Author-once tools.** `Axn::RubyLLM.wrap` turns any Axn into a `RubyLLM::Tool` your chat can call — reuse the same Axn classes you already expose through [axn-mcp](https://github.com/teamshares/axn-mcp), or plain Axns, with no rewrite. The tool's name, JSON Schema, and argument validation all come from the Axn's own contract.

> **Scope note:** This gem covers the subset of RubyLLM functionality that [Teamshares](https://github.com/teamshares) uses internally — single-turn chat, structured output, basic observability, and wrapping Axns as tools. It is intentionally minimal rather than a full-featured wrapper. Feedback and pull requests to extend it are very welcome.

---

## Installation

```ruby
gem "axn-ruby_llm"
```

Configure RubyLLM as normal (e.g. in `config/initializers/ruby_llm.rb`). The default model is `gpt-4o-mini`, but any [RubyLLM-supported provider](https://rubyllm.com/llms) works — just configure the appropriate API key and pass `model:` to override:

```ruby
RubyLLM.configure do |c|
  c.openai_api_key  = ENV["OPENAI_API_KEY"]   # OpenAI
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] # or Anthropic, Gemini, etc.
end
```

Optionally configure gem-level defaults:

```ruby
Axn::RubyLLM.configure do |c|
  c.default_model = "gpt-4o-mini"          # default; override with any RubyLLM model ID
  c.error_headline = "LLM request failed"  # default; prefixes every result.error (see Errors below)
end
```

## Usage

```ruby
result = Axn::RubyLLM.ask(
  prompt: "Summarize this Slack thread: #{thread_text}"
)
result.response  # => "The team decided to..."

# JSON mode
result = Axn::RubyLLM.ask(
  prompt: build_extraction_prompt(doc),
  json: true
)
result.response  # => { "company" => "Acme", "founded" => 1999 }

# With system prompt and model override
result = Axn::RubyLLM.ask(
  prompt: user_message,
  system_prompt: "You are a concise financial analyst.",
  model: "gpt-4o",
  temperature: 0.2
)
```


### Structured output via schema

Pass `schema:` to enable provider-enforced structured output (e.g. OpenAI strict mode) via `RubyLLM::Chat#with_schema`. The result's `response` is the parsed Hash.

```ruby
class CompanyMatch < RubyLLM::Schema
  integer :company_id, description: "ID of the matched company, or null"
  number :confidence, description: "0.0–1.0"
  string :reasoning
end

result = Axn::RubyLLM.ask(
  prompt: "Which company is this thread about?\n\n#{thread_text}",
  schema: CompanyMatch,
)
result.response # => { "company_id" => 42, "confidence" => 0.92, "reasoning" => "..." }
```

`schema:` accepts a [`ruby_llm-schema`](https://github.com/crmne/ruby_llm-schema) class or instance — anything `RubyLLM::Chat#with_schema` accepts, including a raw JSON Schema hash. The `ruby_llm-schema` gem is recommended but not required; declare it in your own Gemfile if you want the DSL. When `schema:` is set, `json: true` is ignored.

### Token counts and cost

Every successful result exposes token usage and cost:

```ruby
result = Axn::RubyLLM.ask(prompt: "...")

result.input_tokens       # => 412  (non-cached input tokens only)
result.cache_read_tokens  # => 80   (tokens served from cache; nil if provider didn't return them)
result.cache_write_tokens # => 20   (tokens written to cache; nil if provider didn't return them)
result.prompt_tokens      # => 512  (input_tokens + cache_read_tokens + cache_write_tokens — total request-side tokens, OpenAI-style)
result.output_tokens      # => 78
result.cost               # => 0.00056 (Float USD total; nil if RubyLLM has no pricing for the model)

# Full breakdown — RubyLLM::Cost struct with per-tier pricing
result.cost_breakdown  # => #<Cost input: 0.0004, output: 0.00016, cache_read: 0.0, ..., total: 0.00056>

# Raw RubyLLM::Message for thinking tokens, raw provider data, etc.
result.raw_message     # => #<RubyLLM::Message ...>
```

`cost` and `cost_breakdown` are both `nil` when RubyLLM lacks pricing for the model (e.g. unknown/custom endpoints). Token counts are nil only if the provider did not return them. `prompt_tokens` is nil only if all three input token fields are nil.

### Errors

Errors are handled via Axn's declarative `error` DSL. Every failure shares a consistent `"LLM request failed: <reason>"` headline (the headline itself is configurable via `c.error_headline =`, e.g. to `"Something went wrong calling the LLM"`; the reasons below are unaffected):
- `JSON::ParserError` → `"LLM request failed: Response was not valid JSON"`
- `RubyLLM::RateLimitError` (HTTP 429, provider-agnostic) → `"LLM request failed: Rate limit reached: <message>"`
- `RubyLLM::OverloadedError` / `ServiceUnavailableError` / `ServerError` (5xx, transient) → `"LLM request failed: Provider temporarily unavailable, try again later: <message>"`
- `RubyLLM::ContextLengthExceededError` → `"LLM request failed: Prompt exceeds the model's context window: <message>"` (message retains the provider's token counts)
- `schema:` set but LLM returned non-JSON → `"LLM request failed: Schema response was not valid JSON"`
- Any other known RubyLLM error — `RubyLLM::Error` (auth, bad request, payment, etc.), `RubyLLM::ConfigurationError`, `ModelNotFoundError`, `PromptNotFoundError`, `InvalidRoleError`, `InvalidToolChoiceError`, `UnsupportedAttachmentError` — or `Faraday::Error` (network/transport failure) → `"LLM request failed: <message>"`
- Any other `StandardError` (i.e. not a recognized RubyLLM/network failure — most likely a bug) → `"LLM request failed"`, with no exception detail leaked into the message

## Tool adapter — wrap any Axn as a RubyLLM::Tool

Any [Axn](https://github.com/teamshares/axn) can be exposed as a `::RubyLLM::Tool` — no adapter-specific mixin required, it's just a normal Axn:

```ruby
class CreateWidget
  include Axn

  description "Creates a widget with the given name"
  expects :name, type: String
  exposes :widget_id

  def call
    expose widget_id: Widget.create!(name:).id
  end
end
```

Pass Axns to `Axn::RubyLLM.ask` via `tools:` and the model can call them as part of the request — RubyLLM runs the tool-call loop internally and `result.response` is the model's final reply:

```ruby
result = Axn::RubyLLM.ask(
  prompt: "Create a widget called Sprocket, then tell me its id.",
  tools: [CreateWidget],
)
result.response # => "Created widget Sprocket (id: 42)."
```

`tools:` accepts a mix of **bare Axn classes** (wrapped automatically) and **already-wrapped tools** from `Axn::RubyLLM.wrap` (a class, or an instance that closed over `ambient_context:` — see below). Pass `tools: Axn::RubyLLM.tools` to expose everything registered under the `:ruby_llm` adapter (see [Enumerating tools](#enumerating-tools-from-the-registry)). The same Axn classes you expose through [axn-mcp](https://github.com/teamshares/axn-mcp) work here unchanged.

> **Token/cost in a tool loop:** a tool call makes multiple model round-trips inside one `ask`. The token counts, `cost`, and `cost_breakdown` are **summed across every turn**, so they reflect the whole call — not just the final response. (`raw_message` is still the final response.)

`Axn::RubyLLM.wrap` is also available directly if you're driving `RubyLLM.chat` yourself rather than going through `ask` — see [Using wrapped tools with RubyLLM directly](#using-wrapped-tools-with-rubyllm-directly).

The tool's name, description, and JSON Schema parameters come straight from the Axn's own contract — the same `description`/`expects`/`exposes` you'd write for any Axn — so a minimal class just works (the tool name defaults from the class name: `CreateWidget` → `create_widget`). Arguments the model supplies are run through axn core's tool `Invoker`: wire types are coerced, and any contract violation — a missing required field, an out-of-schema argument, a wrong type, or a value outside an `inclusion` set (validated at **full depth**, not just the top-level type) — comes back to the model as a clean, correctable `{ error: "Invalid tool arguments: <reason>" }`, and does **not** page `on_exception` as though it were a bug. A model-supplied `ambient_context` is stripped before the Axn runs, so a prompt-injected context can never override the caller's — the wrap's own `ambient_context:` (below) is injected instead.

On success, `execute` returns the exposed values (via `Axn::Extensions::Serialization.render`) as a JSON **string**, not a Hash — `RubyLLM::Chat#handle_tool_calls` only passes a `Content`/`Content::Raw` return through as-is, and otherwise sends `tool_payload.to_s`, which for a Hash produces Ruby's inspect syntax rather than JSON; on failure, `{ error: result.error }`. The same `CreateWidget` class can be wrapped for other transports (e.g. `Axn::MCP.wrap`) with no changes — the contract is declared once.

Options, settable either per-call via `wrap` keywords or once on the Axn via axn's namespaced per-class `configure(:ruby_llm) { |c| ... }` (a `wrap` keyword wins when both are present, then the class-level `configure(:ruby_llm)` value, then this gem's own `Axn::RubyLLM.configure { |c| ... }` global, then the default below):

| Option | Effect |
|---|---|
| `halt_after:` | When `true`, wraps a successful payload in `RubyLLM::Tool::Halt` to stop the agent loop after this call. Default `false`. |
| `provider_params:` | Hash deep-merged into the tool definition sent to the provider (via RubyLLM's `with_params`) — an escape hatch for provider-specific tool fields RubyLLM doesn't model first-class (e.g. OpenAI `strict` function calling, Anthropic tool `cache_control`). Keys mirror that provider's tool shape. Default `{}`. |
| `present_as:` | `:structured` (default) returns the exposed values as a JSON string; `:message` returns `result.message` instead. Same knob as axn-mcp's `present_as:`. |

Set a default once on the Axn with `configure(:ruby_llm)`, and still override per call:

```ruby
class CreateWidget
  include Axn
  configure(:ruby_llm) { |c| c.halt_after = true }   # default for this tool
  # ...
end

Axn::RubyLLM.wrap(CreateWidget)                      # halts after running
Axn::RubyLLM.wrap(CreateWidget, halt_after: false)   # per-call override
```

`configure(:ruby_llm)` needs no `include` beyond `Axn` — every Axn gets it for free (core's namespaced per-class config). It's usually written in the class body as above, but since it's a plain class method you can also call it from outside — e.g. `SomeThirdPartyAxn.configure(:ruby_llm) { |c| ... }` in an initializer, to configure an Axn you don't own. Namespacing is what lets **one base Axn be configured for multiple adapters at once**, each in its own namespace, without collision even when two adapters share a setting name (both this gem and axn-mcp expose `present_as`):

```ruby
class CreateWidget
  include Axn
  # ...

  configure(:ruby_llm) { |c| c.present_as = :message }    # how the RubyLLM tool presents its result
  configure(:mcp)      { |c| c.present_as = :structured } # same setting name, different namespace — no collision
end
```

Pass `ambient_context:` to close over explicit caller context (e.g. `current_user`, `company`) at wrap time, instead of relying on axn's reflective `Current`-based default resolved when the tool runs. This matters when the tool executes somewhere `Current` isn't the right context — e.g. the chat (and therefore the tool call) runs in a background job or a different thread than the request that built the tools:

```ruby
Axn::RubyLLM.wrap(CreateWidget, ambient_context: { company_id: current_company.id })
```

Passing `ambient_context:` returns a tool **instance** (closing over that context) rather than the tool class, since `chat.with_tool` accepts either.

### Using wrapped tools with RubyLLM directly

`Axn::RubyLLM.ask(tools:)` covers the common single-call case. When you're driving `RubyLLM.chat` yourself — multi-turn conversations, streaming, or anything else beyond `ask` — register wrapped tools with RubyLLM's own `with_tool` / `with_tools`, which accept a `RubyLLM::Tool` class or instance:

```ruby
chat = RubyLLM.chat.with_tool(Axn::RubyLLM.wrap(CreateWidget))
chat.ask("Create a widget called Sprocket")

# or register everything under the :ruby_llm adapter at once:
chat = RubyLLM.chat.with_tools(*Axn::RubyLLM.tools)
```

### Tool naming

The name is axn core's canonical, provider-safe `tool_name`: lowercased to `[a-z0-9_]`, leading configured prefixes stripped, snake_cased with single underscores, and never blank (`Admin::CreateWidget` → `admin_create_widget`; a truly anonymous Axn → `"tool"`). Declare `axn_name "..."` on the Axn to override the default. Because it's the same core derivation every adapter uses, a class wrapped by both `Axn::RubyLLM.wrap` and `Axn::MCP.wrap` advertises an identical name — the contract is declared once.

### Enumerating tools from the registry

Rather than wiring each tool up by hand, let axn's tool registry find them and build the whole chat tool list in one call:

```ruby
chat = RubyLLM.chat.with_tools(*Axn::RubyLLM.tools)
```

`Axn::RubyLLM.tools` returns every Axn registered under the `:ruby_llm` adapter, already wrapped as a `::RubyLLM::Tool` — sugar for `Axn::Tools.for(:ruby_llm).map { |axn| Axn::RubyLLM.wrap(axn) }`, in a stable, `tool_name`-sorted order.

**Membership = (directory grant ∪ declaration grant) − exclusions.** An Axn is a `:ruby_llm` tool if either:

- **Directory grant** — its file lives under one of the adapter's `tool_roots`. The default is `["agent_tools"]` (→ `app/agent_tools` in a Rails app), so **an Axn dropped in `app/agent_tools` is a tool with no declaration at all**. Configure the roots with `Axn::RubyLLM.configure { |c| c.tool_roots = ["agent_tools", "actions/tools"] }`; each entry must be a narrow subdir (`app/`, `actions`, `.`, and `..` are rejected, so you can't bulk-expose every action).
- **Declaration grant** — it declares `tool` (every adapter), `tool :ruby_llm`, or carries a `configure(:ruby_llm)` bag.

…unless it opts out: `tool false` (no adapter) or `tool except: :ruby_llm` (keep the directory grant, drop this adapter).

```ruby
class CreateWidget
  include Axn
  tool :ruby_llm                              # add :ruby_llm (on top of any directory grant)
  tool ruby_llm: { present_as: :message }     # …or add it AND set per-adapter options inline
  # ...
end
```

Because both adapters read the registry and the same canonical `tool_name`, the identical set of Axns exposed via `Axn::MCP.tools` advertises identical names — and since both default `tool_roots` to `agent_tools`, an Axn there is authored once and is a tool on both surfaces.

> **Upgrading from the pre-registry API:** `tool :ruby_llm` now **adds** to the directory grant rather than replacing it (declare all adapters, `name:`, `except:`, and per-adapter options in a single `tool` call). And the old global `Axn.config.tool_paths` is **gone** — each adapter owns its own `tool_roots`, so point `Axn::RubyLLM.config.tool_roots` (and `Axn::MCP`'s) at your tool dirs instead.

### Date/Time/Symbol/Integer/Float fields — declare `coerce:`

A provider always sends tool-call arguments as JSON, so a `Date`/`Time`/`DateTime`/`Symbol`/`Integer`/`Float`-typed field arrives as a **String** (e.g. `"2026-07-08"`), which the plain `type:` validator rejects — it checks `value.is_a?(klass)`, not a parse. Declare `coerce:` on that `expects` field so axn parses the wire string before validation runs:

```ruby
expects :scheduled_for, coerce: Date          # sugar for type: { klass: Date, coerce: true }
expects :priority, type: { klass: Symbol, coerce: true } # explicit form, e.g. alongside other type: options
```

Opt-in per field — a field with no `coerce:` is unaffected. A non-String value (a direct Ruby caller's real `Date`, a JSON-native number) is left untouched either way.

### Opaque exposed values — `reject_opaque_exposed_values`

A tool's result is the Axn's exposed values serialized to JSON. A value with **no author-declared JSON form** — no `to_json`/`as_json` of its own — has no honest representation and can only render as an *opaque blob*: `"#<User:0x000…>"` outside Rails, or ActiveSupport's generic instance-variable dump under it. By default that blob ships, because for an LLM tool result an ugly-but-honest string usually beats a failed call.

Set `reject_opaque_exposed_values` (default `false`) to reject it instead. Serialization then raises `Axn::Extensions::Serialization::UnserializableValue` (naming the path, e.g. `records[3].owner`), which the adapter's transport-boundary guard (below) turns into a generic tool error rather than shipping the blob:

```ruby
CreateWidget.configure(:ruby_llm) { |c| c.reject_opaque_exposed_values = true }   # per tool (wins)
Axn::RubyLLM.configure           { |c| c.reject_opaque_exposed_values = true }    # gem-wide default
```

Scope:

- **Output-side only.** It governs `exposes` serialization, never inbound `coerce:` on `expects`.
- **Narrow.** Values with *no honest JSON form at all* — reference cycles, non-finite Floats, non-UTF-8 bytes, two Hash keys colliding onto one property — raise `UnserializableValue` **regardless** of this flag (and surface as a tool error). `reject_opaque_exposed_values` only adds the extra "was this rendering author-declared?" check on top.

### Transport-boundary never-raises guard

A wrapped Axn's own `.call` never raises — core catches action exceptions into a failed `Result` and pages `on_exception` itself. But the transport step that runs *after* the Axn settles — serializing the exposed values, encoding them to JSON — happens outside core's executor and *can* raise (an unserializable value as above, a structure past the JSON encoder's `max_nesting`, or a plain gem bug). Since RubyLLM has no rescue around a tool's `execute`, an escaping exception there would break the whole chat.

So the adapter guards that mapping step (only — the Axn call already reports its own exceptions): any `StandardError` is reported through `Axn.config.on_exception` and the tool returns a **generic** error, `"The tool could not produce a valid response"`. The message is deliberately generic — the actionable detail (exception class, path) rides on the reported exception, not the tool's response. In development (per core's `best_effort_raises_in_dev`) the exception is re-raised instead, so a real bug surfaces loudly rather than being masked. This mirrors [axn-mcp](https://github.com/teamshares/axn-mcp)'s adapter-boundary guard.

### Schema reflection — provider notes

The advertised tool schema is axn's reflected `input_schema`. A few things worth knowing when you care how it lands at a specific provider (Gemini is the strictest — it runs a mandatory OpenAPI-subset converter; OpenAI and Anthropic pass the schema through as-is):

- **Nullable/optional fields** — handled. axn reflects a nullable field as an array-valued `type` (`["integer", "null"]`); the adapter rewrites that to the equivalent `anyOf` form, because Gemini's converter can't read array-valued types and would otherwise collapse the field to `STRING`. No action needed on your part.
- **Array fields — declare `of:`.** `expects :ids, type: Array` reflects to `{type: array}` with no `items`, so the element type isn't advertised (Gemini then assumes `string`; OpenAI *strict* mode requires `items`). Declare the element type — `expects :ids, type: Array, of: Integer` — to advertise `items` correctly.
- **Enums are advertised — use the top-level `inclusion:` key.** `expects :color, type: String, inclusion: %w[red green blue]` (a bare Array, or the long form `inclusion: { in: %w[red green blue] }`) reflects to `{ type: "string", enum: ["red", "green", "blue"] }`, so the model is told the allowed set (an `optional:` field keeps `null` in the enum; a dynamic `in: -> { ... }` is correctly skipped rather than guessed). Note this is the **top-level `inclusion:` option**, not `validate: { inclusion: ... }` — `validate:` is axn's custom-callable hook (it needs `with:`), so that spelling neither enforces nor reflects the set.
- **Conditional expectations** (`expects :token, if: :use_token`) reflect to a JSON Schema `allOf`/`if`/`then` clause. Gemini's converter ignores it — the field degrades to plain-optional (safe: a valid call is never wrongly rejected, but the conditional isn't conveyed to the model). This gem doesn't set OpenAI's `strict` mode, so OpenAI tolerates `allOf` by default; if you opt into strict via `provider_params`, OpenAI will reject `allOf`. Either way, encoding the rule in `description:` is the portable option.

## Testing

In your specs, require the helpers and use `stub_axn_ruby_llm` to stub RubyLLM so `Axn::RubyLLM.ask` returns a canned response without a real API call:

```ruby
require "axn/ruby_llm/rspec"

it "summarizes the thread" do
  stub_axn_ruby_llm("The team agreed to ship on Friday.")
  result = Axn::RubyLLM.ask(prompt: "...")
  expect(result.response).to include("ship on Friday")
end
```

The response is the only required argument — pass it positionally (as above) or as `response:`. A Hash response is auto-JSON-serialized for `json: true` calls; pass `schema:` to route a Hash through the schema path unparsed (and to assert the exact schema class). Token counts and cost default to zero and can be set explicitly to exercise cost/usage logic:

```ruby
stub_axn_ruby_llm({ "company_id" => 42 }, schema: CompanyMatch)
stub_axn_ruby_llm("...", model: "gpt-4o", input_tokens: 100, output_tokens: 50, cost: 0.0023)
stub_axn_ruby_llm("...", cache_read_tokens: 500, cache_write_tokens: 200)
```

Remaining keywords: `model:`, `schema:`, `input_tokens:`, `output_tokens:`, `cache_read_tokens:`, `cache_write_tokens:`, `cost:`. Returns the stubbed chat instance double for further assertions if you need it.

## OpenTelemetry

If your app uses OpenTelemetry, `axn` already wraps every action in an `axn.call` span. This gem enriches that span with LLM-specific attributes automatically — no configuration required:

| Attribute | Value |
|---|---|
| `gen_ai.request.model` | The model requested |
| `gen_ai.response.model` | The model that responded |
| `gen_ai.usage.input_tokens` | Non-cached input token count |
| `gen_ai.usage.output_tokens` | Completion token count |
| `gen_ai.usage.cost` | USD total (non-standard; useful for spend filtering) |
| `axn.ruby_llm.stubbed` | `true` when production gating returned a stub |

For LLM-level tracing (individual `RubyLLM.chat` calls, tool calls, embeddings, prompt content), add [`opentelemetry-instrumentation-ruby_llm`](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm) to your own Gemfile and configure it per its README. It is not a dependency of this gem.

## Production gating

Set the `enabled` config to gate LLM calls — useful for skipping spend in non-production environments. Accepts a Boolean or a callable (evaluated per call):

```ruby
Axn::RubyLLM.configure do |c|
  c.enabled = -> { Rails.env.production? }
  # c.enabled = false  # always stub
  # c.enabled = true   # default; always run
end
```

To read the resolved gate, use **`Axn::RubyLLM.enabled?`** — it invokes an assigned callable and returns a Boolean. (Don't use the DSL-generated `Axn::RubyLLM.config.enabled?`: axn's `Configurable` returns an assigned Proc as-is rather than calling it, so for a callable that predicate is always truthy.)

When disabled, `Axn::RubyLLM.ask` returns a **success** result with obvious stub content, so callers don't need per-callsite branching:

| Field | Stubbed value |
|---|---|
| `response` | `"stubbed response value"` (plain) / `{ "stubbed" => true }` (`json: true` or `schema:`) |
| `raw_message` | Stub struct with `.content`, `.input_tokens`, `.output_tokens`, `.cache_read_tokens`, `.cache_write_tokens`, `.model_id` |
| `input_tokens` / `output_tokens` / `cache_read_tokens` / `cache_write_tokens` / `prompt_tokens` | `0` |
| `cost` | `0.0` |
| `cost_breakdown` | `nil` |
| `stubbed` | `true` |

Check `result.stubbed` if you need to branch on it (e.g. skip downstream writes that would otherwise persist stub LLM output). `result.success` is `"LLM request completed (using stubbed values - actual LLM request disabled)"` for the same purpose; a normal (non-stubbed) call succeeds with `"LLM request completed"`.
