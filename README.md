# axn-ruby_llm

Call LLMs from [Axn](https://github.com/teamshares/axn) actions using [RubyLLM](https://github.com/crmne/ruby_llm), with declarative error handling, optional JSON mode, configurable defaults, and OpenTelemetry tracing.

Part of the `axn-*` extension ecosystem — see also [axn-mcp](https://github.com/teamshares/axn-mcp).

## Installation

```ruby
gem "axn-ruby_llm"
```

Configure RubyLLM as normal (e.g. in `config/initializers/ruby_llm.rb`):

```ruby
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
end
```

Optionally configure gem-level defaults:

```ruby
Axn::RubyLLM.configure do |c|
  c.default_model = "gpt-4o-mini" # default
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

When `opentelemetry-api` is loaded, each LLM call emits an `axn_ruby_llm.ask` span (child of the `axn.call` span) with `llm.model` and `llm.json_mode` attributes, plus `llm.input_tokens` and `llm.output_tokens` when the provider returns them. No configuration required — OTel is feature-detected at runtime.
