# axn-ruby_llm

Call LLMs from [Axn](https://github.com/teamshares/axn) actions using [RubyLLM](https://github.com/crmne/ruby_llm), with declarative error handling, optional JSON mode, configurable defaults, and OpenTelemetry tracing.

Part of the `axn-*` extension ecosystem — see also [axn-mcp](https://github.com/teamshares/axn-mcp).

### Why use this over calling RubyLLM directly?

Three things you'd otherwise build at every callsite:

1. **Structured error handling.** The Axn error DSL declaratively maps `RateLimitError`, `JSON::ParserError`, and generic `StandardError` to clean failure messages. Callers check `result.ok?` instead of wrapping every call in `begin/rescue`.

2. **Production gating.** A single `c.enabled = -> { Rails.env.production? }` in an initializer stubs every LLM call in non-prod environments — no per-callsite guards needed. The stub is typed (`stubbed: true`, `input_tokens: 0`, etc.) so downstream code doesn't need to branch on it either.

3. **Cost/token tracking and OTel tracing, wired up automatically.** Every call exposes `input_tokens`, `output_tokens`, `cost`, and `cost_breakdown` without you doing the `RubyLLM.models.find` lookup manually. OpenTelemetry traces install themselves when the SDK is present — nothing to add to your configure block.

> **Scope note:** This gem covers the subset of RubyLLM functionality that [Teamshares](https://github.com/teamshares) uses internally — single-turn chat, structured output, and basic observability. It is intentionally minimal rather than a full-featured wrapper. Feedback and pull requests to extend it are very welcome.

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
  c.default_model = "gpt-4o-mini" # default; override with any RubyLLM model ID
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

The underlying action class is available as `Axn::RubyLLM::Ask` for cases where you need the full `Axn` interface (`call!`, `call_async`, instrumentation hooks, etc.).

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

Every successful result exposes token usage and cost in two tiers:

```ruby
result = Axn::RubyLLM.ask(prompt: "...")

# Flat (common case)
result.input_tokens    # => 412
result.output_tokens   # => 78
result.cost            # => 0.00056 (Float USD total; nil if RubyLLM has no pricing for the model)

# Resolved breakdown — RubyLLM::Cost struct
result.cost_breakdown  # => #<Cost input: 0.0004, output: 0.00016, cache_read: 0.0, ..., total: 0.00056>

# Full escape hatch — the raw RubyLLM::Message for cache/thinking tokens, etc.
result.raw_message     # => #<RubyLLM::Message ...>
```

`cost` and `cost_breakdown` are both `nil` when RubyLLM lacks pricing for the model (e.g. unknown/custom endpoints). Token counts are nil only if the provider did not return them.

Errors are handled via Axn's declarative `error` DSL:
- `JSON::ParserError` → result fails with `"Failed to parse JSON from LLM response"`
- `RubyLLM::RateLimitError` (HTTP 429, provider-agnostic) → result fails with `"Rate limit reached: <message>"`
- `schema:` set but LLM returned non-JSON → result fails with `"Schema response was not valid JSON"`
- Any other `StandardError` → result fails with `"LLM request failed: <message>"`

## Testing

In your specs, require the helpers and use `stub_axn_ruby_llm`:

```ruby
require "axn/ruby_llm/rspec"

it "summarizes the thread" do
  stub_axn_ruby_llm(response: "The team agreed to ship on Friday.")
  result = Axn::RubyLLM.ask(prompt: "...")
  expect(result.response).to include("ship on Friday")
end
```

## OpenTelemetry

`opentelemetry-instrumentation-ruby_llm` is a **peer dependency** — it is not pulled in automatically, so apps that don't use OpenTelemetry pay no gem weight. To enable tracing, add it to your own Gemfile:

```ruby
gem "opentelemetry-instrumentation-ruby_llm"
```

Tracing is provided by thoughtbot's [`opentelemetry-instrumentation-ruby_llm`](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm), which patches `RubyLLM::Chat#complete` and `RubyLLM::Embedding` with standard `gen_ai.*` GenAI semantic-convention attributes. Spans cover every `RubyLLM.chat` caller (not just `Ask`), tool calls, and embeddings.

Once the gem is present, the instrumentation **auto-installs** when `OpenTelemetry::SDK` is loaded — the host app does not need to add a `c.use` line to its `OpenTelemetry::SDK.configure` block.

```ruby
Axn::RubyLLM.configure do |c|
  c.opentelemetry = :auto # default — install when OpenTelemetry::SDK is defined
  # c.opentelemetry = true  # force install
  # c.opentelemetry = false # disable auto-install (host can still `c.use` it themselves)
end
```

Emitted attributes include `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, and `gen_ai.usage.output_tokens`. Set `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` to also capture system/input/output messages (PII risk — opt in deliberately).

## Production gating

Set `Configuration#enabled` to gate LLM calls — useful for skipping spend in non-production environments. Accepts a Boolean or a callable (evaluated per call):

```ruby
Axn::RubyLLM.configure do |c|
  c.enabled = -> { Rails.env.production? }
  # c.enabled = false  # always stub
  # c.enabled = true   # default; always run
end
```

When disabled, `Ask` returns a **success** result with obvious stub content, so callers don't need per-callsite branching:

| Field | Stubbed value |
|---|---|
| `response` | `"stubbed response value"` (plain) / `{ "stubbed" => true }` (`json: true` or `schema:`) |
| `raw_message` | `Ask::StubMessage` Data instance with `.content`, `.input_tokens`, `.output_tokens`, `.model_id` |
| `input_tokens` / `output_tokens` | `0` |
| `cost` | `0.0` |
| `cost_breakdown` | `nil` |
| `stubbed` | `true` |

Check `result.stubbed` if you need to branch on it (e.g. skip downstream writes that would otherwise persist stub LLM output). The Axn result's `message` is `"disabled - returning stubbed values"` for the same purpose.
