# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::Ask do
  subject(:result) { described_class.call(**params) }

  let(:prompt) { "Summarize this thread." }
  let(:params) { { prompt: } }

  let(:llm_response_content) { "Here is the summary." }
  let(:llm_response_parsed) { nil }
  let(:llm_finish_reason) { :stop }
  let(:llm_input_tokens) { 12 }
  let(:llm_output_tokens) { 34 }
  let(:llm_model_id) { "gpt-4o-mini" }
  let(:llm_tokens) do
    RubyLLM::Tokens.new(input: llm_input_tokens, output: llm_output_tokens, cache_read: nil, cache_write: nil)
  end
  let(:llm_cost) { instance_double(RubyLLM::Cost, total: 0.00056) }
  let(:llm_response) do
    instance_double(
      RubyLLM::Message,
      content: llm_response_content,
      parsed: llm_response_parsed,
      model: llm_model_id,
      finish_reason: llm_finish_reason,
      max_tokens?: llm_finish_reason == :max_tokens,
      content_filtered?: llm_finish_reason == :content_filter,
    )
  end
  let(:chat_instance) { instance_double(RubyLLM::Chat) }

  before do
    allow(RubyLLM).to receive(:chat).and_return(chat_instance)
    allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
    allow(chat_instance).to receive(:with_schema).and_return(chat_instance)
    allow(chat_instance).to receive(:with_temperature).and_return(chat_instance)
    allow(chat_instance).to receive(:with_provider_options).and_return(chat_instance)
    allow(chat_instance).to receive(:with_tools).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).with(prompt, with: nil).and_return(llm_response)
    allow(chat_instance).to receive(:tokens).and_return(llm_tokens)
    allow(chat_instance).to receive(:cost).and_return(llm_cost)
    allow(chat_instance).to receive(:messages).and_return([])
  end

  after do
    Axn::RubyLLM.reset_config!
  end

  context "with default params" do
    it "returns raw text response" do
      expect(result).to be_ok
      expect(result.response).to eq("Here is the summary.")
    end

    it "sets a meaningful success message" do
      expect(result.success).to eq("LLM request completed")
    end

    it "exposes raw_message" do
      expect(result.raw_message).to eq(llm_response)
    end
  end

  context "with a model override" do
    let(:params) { { prompt:, model: "gpt-4o" } }

    it "uses the specified model" do
      expect(RubyLLM).to receive(:chat).with(model: "gpt-4o").and_return(chat_instance)
      result
    end
  end

  context "without a model override" do
    it "uses the configured default model" do
      expect(RubyLLM).to receive(:chat).with(model: Axn::RubyLLM.config.default_model)
      result
    end

    it "respects a custom default_model set via configuration" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      expect(RubyLLM).to receive(:chat).with(model: "o3-mini")
      result
    end
  end

  context "with a system_prompt" do
    let(:params) { { prompt:, system_prompt: "You are a helpful assistant." } }

    it "calls with_instructions on the chat" do
      expect(chat_instance).to receive(:with_instructions).with("You are a helpful assistant.").and_return(chat_instance)
      result
    end

    it "marks the system prompt as a cache boundary with cache_system_prompt: true" do
      expect(chat_instance).to receive(:with_instructions).with("You are a helpful assistant.", cache_until_here: true)
                                                          .and_return(chat_instance)
      described_class.call(**params, cache_system_prompt: true)
    end
  end

  context "with a temperature" do
    let(:params) { { prompt:, temperature: 0.7 } }

    it "calls with_temperature" do
      expect(chat_instance).to receive(:with_temperature).with(0.7).and_return(chat_instance)
      result
    end
  end

  context "with a schema" do
    let(:schema_class) { Class.new }
    let(:llm_response_content) { { "company_id" => 7, "confidence" => 0.9 }.to_json }
    let(:llm_response_parsed) { { "company_id" => 7, "confidence" => 0.9 } }
    let(:params) { { prompt:, schema: schema_class } }

    before do
      allow(chat_instance).to receive(:with_schema).with(schema_class).and_return(chat_instance)
    end

    it "configures chat with the schema and returns the parsed Hash" do
      expect(chat_instance).to receive(:with_schema).with(schema_class).and_return(chat_instance)
      expect(result).to be_ok
      expect(result.response).to eq({ "company_id" => 7, "confidence" => 0.9 })
    end

    context "when the LLM returns malformed JSON despite the schema" do
      before { allow(llm_response).to receive(:parsed).and_raise(JSON::ParserError, "unexpected token") }

      it "fails with the generic JSON parse error message" do
        expect(result).not_to be_ok
        expect(result.error).to eq("LLM request failed: Response was not valid JSON")
      end
    end

    context "when the LLM returns valid JSON that isn't an object despite the schema" do
      let(:llm_response_parsed) { [1, 2, 3] }

      it "fails with a schema-specific error" do
        expect(result).not_to be_ok
        expect(result.error).to eq("LLM request failed: Schema response was not valid JSON")
      end
    end

    context "given an Axn class" do
      let(:schema_class) do
        Class.new do
          include Axn

          exposes :company_id, type: Integer
          exposes :confidence, type: Float
          def call; end
        end
      end
      let(:llm_response_content) { { "company_id" => 1, "confidence" => 0.5 }.to_json }
      let(:llm_response_parsed) { { "company_id" => 1, "confidence" => 0.5 } }
      let(:expected_schema) { schema_class.output_schema.merge(additionalProperties: false) }

      before do
        allow(chat_instance).to receive(:with_schema)
          .with(hash_including(schema: expected_schema))
          .and_return(chat_instance)
      end

      it "forwards the Axn class's output_schema, wrapped with a name" do
        expect(chat_instance).to receive(:with_schema)
          .with(hash_including(schema: expected_schema))
          .and_return(chat_instance)
        expect(result).to be_ok
      end

      it "pins strict: false, rather than leaving it to RubyLLM's own inference" do
        # RubyLLM infers strict: true whenever every property is required (the common case for an
        # Axn's exposed contract, as here) -- but OpenAI's *full* strict mode additionally requires
        # every property to be listed in `required` even when conceptually optional, which axn's
        # reflection doesn't promise. Confirmed live against Anthropic that additionalProperties:
        # false alone is not sufficient reason to also flip on strict inference here.
        expect(chat_instance).to receive(:with_schema)
          .with(hash_including(strict: false))
          .and_return(chat_instance)
        result
      end

      it "injects additionalProperties: false, which both OpenAI strict mode and Anthropic's " \
         "structured output require unconditionally (confirmed live against a real Anthropic call)" do
        expect(chat_instance).to receive(:with_schema)
          .with(hash_including(schema: hash_including(additionalProperties: false)))
          .and_return(chat_instance)
        result
      end

      context "when the Axn exposes a nested fixed-shape object" do
        let(:member) { Struct.new(:field, :validations) }
        let(:schema_class) do
          member_class = member
          Class.new do
            include Axn

            exposes :address, type: Hash, shape: { members: [member_class.new(:street, { type: String })] }
            def call; end
          end
        end
        let(:llm_response_content) { { "address" => { "street" => "Main St" } }.to_json }
        let(:llm_response_parsed) { { "address" => { "street" => "Main St" } } }

        it "injects additionalProperties: false at every nested object level, not just the top" do
          expect(chat_instance).to receive(:with_schema) do |payload|
            expect(payload[:schema][:additionalProperties]).to eq(false)
            expect(payload[:schema][:properties][:address][:additionalProperties]).to eq(false)
            chat_instance
          end
          result
        end

        it "strips minProperties at every nested object level -- Anthropic rejects it outright " \
           "(confirmed live: \"output_config.format.schema: For 'object' type, property " \
           "'minProperties' is not supported\")" do
          # axn emits minProperties: 1 by default on a fixed-shape Hash field (the nested
          # non-blank-by-default contract), which is what surfaced this live.
          expect(schema_class.output_schema.dig(:properties, :address, :minProperties)).to eq(1)

          expect(chat_instance).to receive(:with_schema) do |payload|
            expect(payload[:schema]).not_to have_key(:minProperties)
            expect(payload[:schema][:properties][:address]).not_to have_key(:minProperties)
            chat_instance
          end
          result
        end
      end

      context "when the Axn exposes a map (Hash of:)" do
        let(:schema_class) do
          Class.new do
            include Axn

            exposes :scores, type: Hash, of: { keys: String, values: Integer }
            def call; end
          end
        end
        let(:llm_response_content) { { "scores" => { "a" => 1 } }.to_json }
        let(:llm_response_parsed) { { "scores" => { "a" => 1 } } }

        it "leaves a map's own additionalProperties (its value schema) untouched" do
          expect(chat_instance).to receive(:with_schema) do |payload|
            expect(payload[:schema][:properties][:scores][:additionalProperties]).to eq(type: "integer")
            chat_instance
          end
          result
        end
      end

      context "when the Axn exposes a field literally named minProperties" do
        # Codex review catch: the recursive schema pass walks every Hash, but the `properties`
        # container is a name-to-schema MAP, not a schema node -- it never carries `type`. An
        # ungated delete treated a field literally named `minProperties` as the schema keyword and
        # dropped it from `properties` entirely, while `required` still named it: an invalid
        # schema. Confirmed live before the fix.
        let(:schema_class) do
          Class.new do
            include Axn

            exposes :minProperties, type: Integer
            exposes :other, type: String
            def call; end
          end
        end
        let(:llm_response_content) { { "minProperties" => 3, "other" => "x" }.to_json }
        let(:llm_response_parsed) { { "minProperties" => 3, "other" => "x" } }

        it "preserves the field instead of treating its name as the schema keyword" do
          expect(chat_instance).to receive(:with_schema) do |payload|
            props = payload[:schema][:properties]
            expect(props).to have_key(:minProperties)
            expect(props[:minProperties]).to eq(type: "integer")
            expect(payload[:schema][:required]).to include("minProperties")
            chat_instance
          end
          result
        end
      end
    end
  end

  context "with a custom error_headline configured" do
    before { Axn::RubyLLM.configure { |c| c.error_headline = "Something went wrong calling the LLM" } }

    it "prefixes failures with the configured headline instead of the default" do
      allow(chat_instance).to receive(:ask).and_raise(RubyLLM::UnauthorizedError.new("Invalid API key"))
      expect(result.error).to eq("Something went wrong calling the LLM: Invalid API key")
    end
  end

  context "when the provider raises a rate limit error" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(RubyLLM::RateLimitError.new("429 Too Many Requests"))
    end

    it "fails with a rate limit message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed: Rate limit reached: 429 Too Many Requests")
    end
  end

  context "when an unrecognized StandardError occurs (e.g. a bug)" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(StandardError.new("undefined method 'foo' for nil"))
    end

    it "fails with the bare headline, without leaking the exception message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed")
    end
  end

  context "when RubyLLM raises one of its own error types" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(RubyLLM::UnauthorizedError.new("Invalid API key - check your credentials"))
    end

    it "surfaces the provider's message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed: Invalid API key - check your credentials")
    end
  end

  context "when the underlying HTTP transport fails (e.g. a timeout)" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(Faraday::TimeoutError.new("execution expired"))
    end

    it "surfaces the transport error's message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed: execution expired")
    end
  end

  context "when RubyLLM raises one of its non-HTTP error types" do
    {
      "RubyLLM::ConfigurationError" => [RubyLLM::ConfigurationError, "No API key configured for openai"],
      "RubyLLM::ModelNotFoundError" => [RubyLLM::ModelNotFoundError, "Model gpt-99 not found"],
      "RubyLLM::ModelRegistryError" => [RubyLLM::ModelRegistryError, "registry fetch failed"],
      "RubyLLM::PendingToolCallsError" => [RubyLLM::PendingToolCallsError, "unanswered tool calls"],
      "RubyLLM::CancelledError" => [RubyLLM::CancelledError, "Chat generation cancelled"],
    }.each do |name, (klass, message)|
      context "with #{name}" do
        before { allow(chat_instance).to receive(:ask).and_raise(klass.new(message)) }

        it "surfaces the error's message rather than the bare headline" do
          expect(result).not_to be_ok
          expect(result.error).to eq("LLM request failed: #{message}")
        end
      end
    end
  end

  context "when the provider is overloaded or temporarily unavailable" do
    {
      "RubyLLM::OverloadedError" => RubyLLM::OverloadedError,
      "RubyLLM::ServiceUnavailableError" => RubyLLM::ServiceUnavailableError,
      "RubyLLM::ServerError" => RubyLLM::ServerError,
    }.each do |name, klass|
      context "with #{name}" do
        before { allow(chat_instance).to receive(:ask).and_raise(klass.new("please try again later")) }

        it "fails with a retryable-specific message" do
          expect(result).not_to be_ok
          expect(result.error).to eq("LLM request failed: Provider temporarily unavailable, try again later: please try again later")
        end
      end
    end
  end

  context "when the prompt exceeds the model's context window" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(RubyLLM::ContextLengthExceededError.new("maximum context length is 8192 tokens"))
    end

    it "fails with an actionable, detail-preserving message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed: Prompt exceeds the model's context window: maximum context length is 8192 tokens")
    end
  end

  describe "token counts and cost" do
    it "exposes input_tokens and output_tokens from the chat's token ledger" do
      expect(result.input_tokens).to eq(12)
      expect(result.output_tokens).to eq(34)
      expect(result.cache_read_tokens).to be_nil
      expect(result.cache_write_tokens).to be_nil
      expect(result.prompt_tokens).to eq(12) # input only, no cache tokens
    end

    it "reads the usage ledger only after the chat has run (a real Chat's ledger is empty before #ask)" do
      asked = false
      allow(chat_instance).to receive(:ask).with(prompt, with: nil) do
        asked = true
        llm_response
      end
      allow(chat_instance).to receive(:tokens) do
        asked ? llm_tokens : RubyLLM::Tokens.new(input: nil, output: nil, cache_read: nil, cache_write: nil)
      end
      allow(chat_instance).to receive(:cost) { asked ? llm_cost : instance_double(RubyLLM::Cost, total: nil) }

      expect(result.total_input_tokens).to eq(12)
      expect(result.output_tokens).to eq(34)
      expect(result.cost).to eq(0.00056)
    end

    it "exposes total cost as a Float via cost" do
      expect(result.cost).to eq(0.00056)
    end

    it "exposes the full Cost object via cost_breakdown" do
      expect(result.cost_breakdown).to eq(llm_cost)
    end

    context "when cache tokens are present" do
      let(:llm_tokens) { RubyLLM::Tokens.new(input: 100, output: 20, cache_read: 30, cache_write: 10) }

      it "exposes total_input_tokens as uncached + cache_read + cache_write" do
        expect(result.total_input_tokens).to eq(140)
      end

      it "exposes uncached_input_tokens as RubyLLM's standard-rate Tokens#input" do
        expect(result.uncached_input_tokens).to eq(100)
      end

      it "keeps the deprecated fields' values: input_tokens is uncached, prompt_tokens is the total" do
        expect(result.input_tokens).to eq(100)
        expect(result.prompt_tokens).to eq(140)
      end
    end

    context "when the provider returns no token data" do
      let(:llm_tokens) { RubyLLM::Tokens.new(input: nil, output: nil, cache_read: nil, cache_write: nil) }

      it "exposes nil token counts and nil prompt_tokens" do
        expect(result.total_input_tokens).to be_nil
        expect(result.uncached_input_tokens).to be_nil
        expect(result.input_tokens).to be_nil
        expect(result.output_tokens).to be_nil
        expect(result.prompt_tokens).to be_nil
      end
    end

    context "when RubyLLM has no pricing for the model" do
      let(:llm_cost) { instance_double(RubyLLM::Cost, total: nil) }

      it "still succeeds with nil cost" do
        expect(result).to be_ok
        expect(result.cost).to be_nil
      end

      it "still exposes the Cost object and token counts" do
        expect(result.cost_breakdown).to eq(llm_cost)
        expect(result.input_tokens).to eq(12)
        expect(result.output_tokens).to eq(34)
        expect(result.prompt_tokens).to eq(12)
      end
    end
  end

  describe "thinking_tokens and server_tool_use" do
    let(:llm_tokens) do
      RubyLLM::Tokens.new(input: 10, output: 50, thinking: 30, server_tool_use: { "web_search_requests" => 2 })
    end

    it "exposes the ledger's thinking tokens and per-use server-tool counters" do
      expect(result.thinking_tokens).to eq(30)
      expect(result.server_tool_use).to eq({ "web_search_requests" => 2 })
    end

    context "when the provider reports neither" do
      let(:llm_tokens) { RubyLLM::Tokens.new(input: 10, output: 5) }

      it "exposes nil for both" do
        expect(result.thinking_tokens).to be_nil
        expect(result.server_tool_use).to be_nil
      end
    end
  end

  describe "finish_reason" do
    it "exposes the final message's normalized finish_reason" do
      expect(result.finish_reason).to eq(:stop)
    end

    context "when the response was cut off by the output token limit" do
      let(:llm_finish_reason) { :max_tokens }

      it "fails with an explicit reason instead of returning truncated text as a success" do
        expect(result).not_to be_ok
        expect(result.error).to eq("LLM request failed: Response was cut off by the output token limit before it finished")
      end

      it "still exposes usage, cost, raw_message and finish_reason for the call that was paid for" do
        expect(result.total_input_tokens).to eq(12)
        expect(result.output_tokens).to eq(34)
        expect(result.cost).to eq(0.00056)
        expect(result.raw_message).to eq(llm_response)
        expect(result.finish_reason).to eq(:max_tokens)
      end

      context "with a schema" do
        let(:params) { { prompt:, schema: { type: "object" } } }

        it "reports the truncation rather than a misleading JSON parse error" do
          expect(result.error).to eq("LLM request failed: Response was cut off by the output token limit before it finished")
        end
      end
    end

    context "when a provider content filter blocked the response" do
      let(:llm_finish_reason) { :content_filter }

      it "fails with an explicit reason" do
        expect(result).not_to be_ok
        expect(result.error).to eq("LLM request failed: Response was blocked by the provider's content filter")
      end
    end

    context "when disabled (stubbed path)" do
      before { Axn::RubyLLM.configure { |c| c.enabled = false } }

      it "exposes a nil finish_reason, nil thinking_tokens and nil server_tool_use" do
        expect(result.finish_reason).to be_nil
        expect(result.thinking_tokens).to be_nil
        expect(result.server_tool_use).to be_nil
      end
    end
  end

  describe "Axn::RubyLLM.ask shortcut" do
    it "delegates to Ask.call" do
      result = Axn::RubyLLM.ask(prompt:)
      expect(result).to be_ok
      expect(result.response).to eq("Here is the summary.")
    end

    it "exposes ask! that delegates to Ask.call!" do
      expect(Axn::RubyLLM.ask!(prompt:).response).to eq("Here is the summary.")
    end

    it "exposes stubbed=false on normal calls" do
      expect(Axn::RubyLLM.ask(prompt:).stubbed).to eq(false)
    end

    # These verify the shortcut is wired via mount_axn (not hand-written delegation).
    # ask_async and Axns::Ask only exist when mount_axn ran; they'd be absent with the
    # old `def ask(**) = Ask.call(**)` approach.
    it "exposes ask_async (generated by mount_axn)" do
      expect(Axn::RubyLLM).to respond_to(:ask_async)
    end

    it "registers Axn::RubyLLM::Axns::Ask pointing at the underlying action class" do
      expect(Axn::RubyLLM::Axns::Ask).to be(Axn::RubyLLM::Ask)
    end
  end

  describe "production gating via configuration.enabled" do
    context "when enabled = false" do
      before { Axn::RubyLLM.configure { |c| c.enabled = false } }

      it "returns a success result without touching RubyLLM" do
        expect(RubyLLM).not_to receive(:chat)
        expect(result).to be_ok
      end

      it "sets a success message explaining the stubbed values" do
        expect(result.success).to eq("LLM request completed (using stubbed values - actual LLM request disabled)")
      end

      it "exposes a stub response and stubbed flag" do
        expect(result.response).to eq("stubbed response value")
        expect(result.stubbed).to eq(true)
        expect(result.raw_message.content).to eq("stubbed response value")
        expect(result.raw_message.model).to eq("stubbed")
        expect(result.total_input_tokens).to eq(0)
        expect(result.uncached_input_tokens).to eq(0)
        expect(result.input_tokens).to eq(0)
        expect(result.output_tokens).to eq(0)
        expect(result.cache_read_tokens).to eq(0)
        expect(result.cache_write_tokens).to eq(0)
        expect(result.prompt_tokens).to eq(0)
        expect(result.cost).to eq(0.0)
        expect(result.cost_breakdown).to be_nil
      end
    end

    context "when enabled = -> { false }" do
      before { Axn::RubyLLM.configure { |c| c.enabled = -> { false } } }

      it "stubs the call" do
        expect(result).to be_ok
        expect(result.stubbed).to eq(true)
      end
    end

    context "when enabled = -> { true }" do
      before { Axn::RubyLLM.configure { |c| c.enabled = -> { true } } }

      it "runs the normal call path" do
        expect(result).to be_ok
        expect(result.stubbed).to eq(false)
        expect(result.response).to eq("Here is the summary.")
      end
    end

    context "with a schema while disabled" do
      let(:schema_class) { Class.new }
      let(:params) { { prompt:, schema: schema_class } }
      before { Axn::RubyLLM.configure { |c| c.enabled = false } }

      it "stubs with a non-empty Hash" do
        expect(result.response).to eq({ "stubbed" => true })
        expect(result.stubbed).to eq(true)
      end
    end
  end

  describe "tools:" do
    let(:widget) do
      Class.new do
        include Axn

        description "creates a widget"
        expects :name, type: String
        def call; end
      end
    end

    it "wraps a bare Axn class and registers it with the chat" do
      registered = nil
      allow(chat_instance).to receive(:with_tools) do |*tools|
        registered = tools
        chat_instance
      end

      described_class.call(prompt:, tools: [widget])

      expect(registered).to all(be < RubyLLM::Tool)
      expect(registered.map { |t| t.new.name }).to eq([widget.tool_name])
    end

    it "passes an already-wrapped tool through unchanged (e.g. one closed over ambient_context)" do
      wrapped = Axn::RubyLLM.wrap(widget)
      expect(chat_instance).to receive(:with_tools).with(wrapped).and_return(chat_instance)

      described_class.call(prompt:, tools: [wrapped])
    end

    it "does not register tools when none are given" do
      expect(chat_instance).not_to receive(:with_tools)

      described_class.call(prompt:)
    end
  end

  describe "provider_tools: and tool_options: pass-through" do
    let(:mcp_options) { { mcp: { name: "metabase", url: "https://example.com/mcp", headers: { "X-API-KEY" => "secret" } } } }

    it "forwards provider_tools: to with_provider_tools" do
      expect(chat_instance).to receive(:with_provider_tools).with(**mcp_options).and_return(chat_instance)
      described_class.call(prompt:, provider_tools: mcp_options)
    end

    it "does not call with_provider_tools when none is given" do
      expect(chat_instance).not_to receive(:with_provider_tools)
      described_class.call(prompt:)
    end

    it "forwards tool_options: to with_tool_options" do
      expect(chat_instance).to receive(:with_tool_options).with(concurrency: :threads, calls: :many).and_return(chat_instance)
      described_class.call(prompt:, tool_options: { concurrency: :threads, calls: :many })
    end

    it "does not call with_tool_options when none is given" do
      expect(chat_instance).not_to receive(:with_tool_options)
      described_class.call(prompt:)
    end
  end

  describe "model resolution pass-through" do
    it "forwards provider:/protocol:/assume_model_exists:/context: to RubyLLM.chat" do
      context = instance_double(RubyLLM::Context)
      expect(RubyLLM).to receive(:chat)
        .with(model: "my-model", provider: :openai, protocol: :chat_completions, assume_model_exists: true, context:)
        .and_return(chat_instance)
      described_class.call(prompt:, model: "my-model", provider: :openai, protocol: :chat_completions,
                           assume_model_exists: true, context:)
    end
  end

  describe "Chat#with_* pass-through" do
    {
      max_output_tokens: [:with_max_output_tokens, 500, [500]],
      end_user: [:with_end_user, "user-hash-123", ["user-hash-123"]],
      provider_options: [:with_provider_options, { service_tier: "flex" }, [{ service_tier: "flex" }]],
      headers: [:with_headers, { "anthropic-beta" => "x" }, [{ "anthropic-beta" => "x" }]],
      thinking: [:with_thinking, { effort: :high }, [{ effort: :high }]],
      citations: [:with_citations, true, [true]],
      caching: [:with_caching, { ttl: "1h" }, [{ ttl: "1h" }]],
      compaction: [:with_compaction, { at: 50_000 }, [{ at: 50_000 }]],
    }.each do |input, (method, value, args)|
      it "forwards #{input}: to #{method}" do
        expect(chat_instance).to receive(method).with(*args).and_return(chat_instance)
        described_class.call(prompt:, input => value)
      end

      it "does not call #{method} when #{input}: is omitted" do
        allow(chat_instance).to receive(method)
        described_class.call(prompt:)
        expect(chat_instance).not_to have_received(method)
      end
    end

    %i[thinking citations caching compaction].each do |input|
      it "forwards an explicit #{input}: false (a real instruction, not an omission)" do
        expect(chat_instance).to receive(:"with_#{input}").with(false).and_return(chat_instance)
        described_class.call(prompt:, input => false)
      end
    end

    it "forwards fallbacks: to with_fallbacks, with fallback_on: as on:" do
      expect(chat_instance).to receive(:with_fallbacks).with("claude-haiku-4-5", "gpt-4.1-mini", on: [RubyLLM::ServerError])
                                                       .and_return(chat_instance)
      described_class.call(prompt:, fallbacks: %w[claude-haiku-4-5 gpt-4.1-mini], fallback_on: [RubyLLM::ServerError])
    end

    it "leaves with_fallbacks' default error classes alone when fallback_on: is omitted" do
      expect(chat_instance).to receive(:with_fallbacks).with("claude-haiku-4-5").and_return(chat_instance)
      described_class.call(prompt:, fallbacks: ["claude-haiku-4-5"])
    end
  end

  describe "attachments:" do
    it "passes attachments to Chat#ask as with:" do
      expect(chat_instance).to receive(:ask).with(prompt, with: ["report.pdf"]).and_return(llm_response)
      described_class.call(prompt:, attachments: ["report.pdf"])
    end
  end

  describe "history:" do
    let(:history) { [{ role: :user, content: "Earlier question" }, { role: :assistant, content: "Earlier answer" }] }
    let(:seeded) do
      history.map { |h| instance_double(RubyLLM::Message, role: h[:role], content: h[:content], tool_calls: nil, tool_call_id: nil, server_tool_calls: nil) }
    end
    let(:new_user_message) do
      instance_double(RubyLLM::Message, role: :user, content: prompt, tool_calls: nil, tool_call_id: nil, server_tool_calls: nil)
    end

    before do
      allow(llm_response).to receive_messages(role: :assistant, tool_calls: nil, tool_call_id: nil, server_tool_calls: nil)
      allow(chat_instance).to receive(:messages=)
    end

    it "seeds the chat's messages before setting the system prompt (which messages= would otherwise wipe)" do
      allow(chat_instance).to receive(:messages).and_return(seeded)
      expect(chat_instance).to receive(:messages=).with(history).ordered
      expect(chat_instance).to receive(:with_instructions).with("Be terse.").ordered.and_return(chat_instance)
      described_class.call(prompt:, history:, system_prompt: "Be terse.")
    end

    it "leaves the seeded turns out of transcript" do
      allow(chat_instance).to receive(:messages).and_return(seeded, [*seeded, new_user_message, llm_response])
      result = described_class.call(prompt:, history:)
      expect(result.transcript.map { |m| m[:content] }).to eq([prompt, "Here is the summary."])
    end
  end

  describe "on_chunk:" do
    it "passes the callable to Chat#ask as its streaming block" do
      chunks = []
      on_chunk = ->(chunk) { chunks << chunk }
      allow(chat_instance).to receive(:ask).with(prompt, with: nil) do |*_args, &block|
        block.call(:chunk1)
        block.call(:chunk2)
        llm_response
      end

      result = described_class.call(prompt:, on_chunk:)

      expect(chunks).to eq(%i[chunk1 chunk2])
      expect(result.response).to eq("Here is the summary.")
    end
  end

  describe "max_tool_calls:" do
    let(:tool_class) do
      Class.new(RubyLLM::Tool) do
        def self.name = "EchoTool"
        def execute = "ran"
      end
    end

    let(:other_tool_class) do
      Class.new(RubyLLM::Tool) do
        def self.name = "OtherTool"
        def execute = "ran other"
      end
    end

    def registered_tools(tools: [tool_class], **params)
      registered = nil
      allow(chat_instance).to receive(:with_tools) do |*registered_now|
        registered = registered_now
        chat_instance
      end
      described_class.call(prompt:, tools:, **params)
      registered
    end

    it "caps the total tool calls, then answers each further call with a budget-exhausted error" do
      tool = registered_tools(max_tool_calls: 2).first

      expect([tool.call, tool.call]).to eq(%w[ran ran])
      expect(tool.call[:error]).to start_with("Tool call budget exhausted (2 tool calls allowed)")
    end

    it "shares one budget across every tool" do
      first, second = registered_tools(tools: [tool_class, other_tool_class], max_tool_calls: 1)

      expect(first.call).to eq("ran")
      expect(second.call[:error]).to include("budget exhausted")
    end

    it "does not mutate a caller-supplied tool instance" do
      instance = tool_class.new
      allow(chat_instance).to receive(:with_tools).and_return(chat_instance)
      described_class.call(prompt:, tools: [instance], max_tool_calls: 1)

      3.times { expect(instance.call).to eq("ran") }
    end

    it "registers tools unguarded when max_tool_calls: is omitted" do
      expect(registered_tools).to eq([tool_class])
    end
  end

  describe "transcript" do
    let(:tool_call) { instance_double(RubyLLM::ToolCall, name: "execute_sql", arguments: { "sql" => "select 1" }, remote?: false) }
    let(:assistant_message) do
      instance_double(RubyLLM::Message, role: :assistant, content: nil, tool_calls: { "call_1" => tool_call },
                                        tool_call_id: nil, server_tool_calls: nil)
    end
    let(:tool_result_message) do
      instance_double(RubyLLM::Message, role: :tool, content: "1", tool_calls: nil, tool_call_id: "call_1", server_tool_calls: nil)
    end
    let(:system_message) do
      instance_double(RubyLLM::Message, role: :system, content: "You are helpful.", tool_calls: nil, tool_call_id: nil, server_tool_calls: nil)
    end

    before do
      allow(llm_response).to receive_messages(role: :assistant, tool_calls: nil, tool_call_id: nil, server_tool_calls: nil)
      allow(chat_instance).to receive(:messages).and_return([system_message, assistant_message, tool_result_message, llm_response])
    end

    it "excludes the system message and reshapes every other message into a plain Hash" do
      expected_tool_call = { name: "execute_sql", arguments: { "sql" => "select 1" }, remote: false }
      expect(result.transcript).to eq([
                                        { role: :assistant, content: nil, tool_calls: { "call_1" => expected_tool_call },
                                          tool_call_id: nil, server_tool_calls: nil },
                                        { role: :tool, content: "1", tool_calls: nil, tool_call_id: "call_1", server_tool_calls: nil },
                                        { role: :assistant, content: "Here is the summary.", tool_calls: nil, tool_call_id: nil, server_tool_calls: nil },
                                      ])
    end

    context "when disabled (stubbed path)" do
      before { Axn::RubyLLM.configure { |c| c.enabled = false } }

      it "exposes an empty transcript" do
        expect(result.transcript).to eq([])
      end
    end
  end

  describe "on_remote_tool_approval:" do
    let(:pending_call) { instance_double(RubyLLM::ToolCall, name: "execute_sql", arguments: { "sql" => "select 1" }, remote?: true) }
    let(:resumed_message) { instance_double(RubyLLM::Message, content: "resumed answer", parsed: nil, model: llm_model_id, finish_reason: :stop, max_tokens?: false, content_filtered?: false) }

    before do
      allow(chat_instance).to receive(:messages).and_return([])
    end

    context "when the chat pauses on a pending approval" do
      before do
        # First #ask parks on the approval; the approval decision lets a subsequent #complete finish it.
        call_count = 0
        allow(chat_instance).to receive(:awaiting_approval?) do
          call_count += 1
          call_count == 1
        end
        allow(chat_instance).to receive(:pending_approvals).and_return([pending_call])
        allow(chat_instance).to receive(:complete).and_return(resumed_message)
        allow(chat_instance).to receive(:approve)
        allow(chat_instance).to receive(:deny)
      end

      it "approves when the callback returns truthy, then resumes with #complete" do
        expect(chat_instance).to receive(:approve).with(pending_call)
        expect(chat_instance).not_to receive(:deny)

        result = described_class.call(prompt:, on_remote_tool_approval: ->(_tool_call) { true })

        expect(result).to be_ok
        expect(result.raw_message).to eq(resumed_message)
      end

      it "denies when the callback returns falsy" do
        expect(chat_instance).to receive(:deny).with(pending_call)
        expect(chat_instance).not_to receive(:approve)

        described_class.call(prompt:, on_remote_tool_approval: ->(_tool_call) { false })
      end

      it "hands the callback the pending ToolCall" do
        seen = nil
        described_class.call(prompt:, on_remote_tool_approval: ->(tool_call) { seen = tool_call })
        expect(seen).to eq(pending_call)
      end
    end

    context "when the chat never pauses on an approval" do
      before { allow(chat_instance).to receive(:awaiting_approval?).and_return(false) }

      it "does not drive the loop or touch approve/deny" do
        expect(chat_instance).not_to receive(:complete)
        expect(chat_instance).not_to receive(:approve)
        expect(chat_instance).not_to receive(:deny)

        result = described_class.call(prompt:, on_remote_tool_approval: ->(_tool_call) { true })
        expect(result.raw_message).to eq(llm_response)
      end
    end

    context "without on_remote_tool_approval" do
      it "never checks awaiting_approval? -- ask's own result is final, matching pre-existing behavior" do
        expect(chat_instance).not_to receive(:awaiting_approval?)
        result
      end
    end
  end

  context "across a tool loop (multiple model round-trips in one ask)" do
    let(:final_turn) { instance_double(RubyLLM::Message, content: "final answer", parsed: nil, model: llm_model_id, finish_reason: :stop, max_tokens?: false, content_filtered?: false) }
    let(:llm_tokens) { RubyLLM::Tokens.new(input: 150, output: 30, cache_read: nil, cache_write: nil) }
    let(:llm_cost) { instance_double(RubyLLM::Cost, total: 0.0045) }

    before do
      # RubyLLM's own Chat#tokens / Chat#cost aggregate every provider attempt across the whole
      # tool loop -- not just the final turn -- so Ask reads the chat-wide ledger, not
      # chat.messages. The stubbed ledger here already reflects that whole-loop total.
      allow(chat_instance).to receive(:ask).with(prompt, with: nil).and_return(final_turn)
    end

    it "sums token usage and cost across every turn, not just the final one" do
      expect(result.input_tokens).to eq(150)
      expect(result.output_tokens).to eq(30)
      expect(result.cost).to eq(0.0045)
    end

    it "still exposes the final turn as raw_message" do
      expect(result.raw_message).to eq(final_turn)
    end
  end
end

RSpec.describe "Axn::RubyLLM::Ask OTel attribute enrichment" do
  let(:prompt) { "Summarize this." }

  let(:llm_response) do
    instance_double(RubyLLM::Message, content: "summary", parsed: nil, model: "gpt-4o-mini", finish_reason: :stop, max_tokens?: false, content_filtered?: false)
  end
  let(:llm_tokens) { RubyLLM::Tokens.new(input: 10, output: 5, cache_read: nil, cache_write: nil) }
  let(:llm_cost) { instance_double(RubyLLM::Cost, total: nil) }
  let(:chat_instance) { instance_double(RubyLLM::Chat) }

  # The one span in play: axn's own tracer, which record_otel_attributes! reaches via
  # Axn::Extensions::Tracing.annotate_span -- not a second, independently-stubbed OpenTelemetry double.
  let(:axn_span) do
    double("AxnSpan").tap do |s|
      allow(s).to receive(:set_attribute)
      allow(s).to receive(:status=)
      allow(s).to receive(:record_exception)
    end
  end
  let(:fake_axn_tracer) do
    double("Tracer").tap { |t| allow(t).to receive(:in_span).and_yield(axn_span) }
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(chat_instance)
    allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
    allow(chat_instance).to receive(:with_schema).and_return(chat_instance)
    allow(chat_instance).to receive(:with_temperature).and_return(chat_instance)
    allow(chat_instance).to receive(:with_provider_options).and_return(chat_instance)
    allow(chat_instance).to receive(:with_tools).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).and_return(llm_response)
    allow(chat_instance).to receive(:tokens).and_return(llm_tokens)
    allow(chat_instance).to receive(:cost).and_return(llm_cost)
    allow(chat_instance).to receive(:messages).and_return([])
    Axn.config.tracer = fake_axn_tracer
  end

  after do
    Axn::RubyLLM.reset_config!
    Axn.config.reset!(:tracer)
  end

  it "sets gen_ai and cost attributes on the current span for a normal call" do
    Axn::RubyLLM.ask(prompt:)
    expect(axn_span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o-mini")
    expect(axn_span).to have_received(:set_attribute).with("gen_ai.response.model", "gpt-4o-mini")
    expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 10)
    expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 5)
    expect(axn_span).to have_received(:set_attribute).with("axn.ruby_llm.stubbed", false)
  end

  it "sets cost attribute when cost is available" do
    allow(chat_instance).to receive(:cost).and_return(instance_double(RubyLLM::Cost, total: 0.0007))
    Axn::RubyLLM.ask(prompt:)
    expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.cost", 0.0007)
  end

  context "when the provider reports cache tokens" do
    let(:llm_tokens) { RubyLLM::Tokens.new(input: 9, output: 5, cache_read: 40_000, cache_write: 18_000) }

    it "reports gen_ai.usage.input_tokens as the total including cached tokens (OTel semconv), plus the cache sub-totals" do
      Axn::RubyLLM.ask(prompt:)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 58_009)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.cache_read.input_tokens", 40_000)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.cache_creation.input_tokens", 18_000)
    end
  end

  it "omits the cache attributes when the provider doesn't report them" do
    Axn::RubyLLM.ask(prompt:)
    expect(axn_span).not_to have_received(:set_attribute).with("gen_ai.usage.cache_read.input_tokens", anything)
    expect(axn_span).not_to have_received(:set_attribute).with("gen_ai.usage.cache_creation.input_tokens", anything)
  end

  it "stamps the gem version, so dashboards can separate spans across a change in attribute meaning" do
    Axn::RubyLLM.ask(prompt:)
    expect(axn_span).to have_received(:set_attribute).with("axn.ruby_llm.version", Axn::RubyLLM::VERSION)
  end

  context "when disabled (stubbed path)" do
    before { Axn::RubyLLM.configure { |c| c.enabled = false } }

    it "sets request model, zero tokens, zero cost, and stubbed=true; no response model" do
      Axn::RubyLLM.ask(prompt:)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o-mini")
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 0)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 0)
      expect(axn_span).to have_received(:set_attribute).with("gen_ai.usage.cost", 0.0)
      expect(axn_span).to have_received(:set_attribute).with("axn.ruby_llm.stubbed", true)
      expect(axn_span).not_to have_received(:set_attribute).with("gen_ai.response.model", anything)
    end
  end

  context "when there is no active span (no tracer configured)" do
    before { Axn.config.reset!(:tracer) }

    it "still succeeds and makes no attribute calls" do
      result = Axn::RubyLLM.ask(prompt:)
      expect(result).to be_ok
      expect(axn_span).not_to have_received(:set_attribute)
    end
  end

  context "when set_attribute raises" do
    before { allow(axn_span).to receive(:set_attribute).and_raise(StandardError, "span closed") }

    it "still succeeds" do
      expect(Axn::RubyLLM.ask(prompt:)).to be_ok
    end
  end
end
