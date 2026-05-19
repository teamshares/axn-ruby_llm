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
