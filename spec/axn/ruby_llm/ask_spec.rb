# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::Ask do
  subject(:result) { described_class.call(**params) }

  let(:prompt) { "Summarize this thread." }
  let(:params) { { prompt: } }

  let(:llm_response_content) { "Here is the summary." }
  let(:llm_response_parsed) { nil }
  let(:llm_input_tokens) { 12 }
  let(:llm_output_tokens) { 34 }
  let(:llm_model_id) { "gpt-4o-mini" }
  let(:llm_tokens) do
    instance_double(RubyLLM::Tokens, input: llm_input_tokens, output: llm_output_tokens, cache_read: nil, cache_write: nil)
  end
  let(:llm_cost) { instance_double(RubyLLM::Cost, total: 0.00056) }
  let(:llm_response) do
    instance_double(
      RubyLLM::Message,
      content: llm_response_content,
      parsed: llm_response_parsed,
      model: llm_model_id,
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
    allow(chat_instance).to receive(:ask).with(prompt).and_return(llm_response)
    allow(chat_instance).to receive(:tokens).and_return(llm_tokens)
    allow(chat_instance).to receive(:cost).and_return(llm_cost)
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

    it "exposes total cost as a Float via cost" do
      expect(result.cost).to eq(0.00056)
    end

    it "exposes the full Cost object via cost_breakdown" do
      expect(result.cost_breakdown).to eq(llm_cost)
    end

    context "when cache tokens are present" do
      let(:llm_tokens) { instance_double(RubyLLM::Tokens, input: 100, output: 20, cache_read: 30, cache_write: 10) }

      it "includes cache tokens in prompt_tokens" do
        expect(result.prompt_tokens).to eq(140) # input + cache_read + cache_write
      end
    end

    context "when the provider returns no token data" do
      let(:llm_tokens) { instance_double(RubyLLM::Tokens, input: nil, output: nil, cache_read: nil, cache_write: nil) }

      it "exposes nil token counts and nil prompt_tokens" do
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

  context "across a tool loop (multiple model round-trips in one ask)" do
    let(:final_turn) { instance_double(RubyLLM::Message, content: "final answer", parsed: nil, model: llm_model_id) }
    let(:llm_tokens) { instance_double(RubyLLM::Tokens, input: 150, output: 30, cache_read: nil, cache_write: nil) }
    let(:llm_cost) { instance_double(RubyLLM::Cost, total: 0.0045) }

    before do
      # RubyLLM's own Chat#tokens / Chat#cost aggregate every provider attempt across the whole
      # tool loop -- not just the final turn -- so Ask reads the chat-wide ledger, not
      # chat.messages. The stubbed ledger here already reflects that whole-loop total.
      allow(chat_instance).to receive(:ask).with(prompt).and_return(final_turn)
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
    instance_double(RubyLLM::Message, content: "summary", parsed: nil, model: "gpt-4o-mini")
  end
  let(:llm_tokens) { instance_double(RubyLLM::Tokens, input: 10, output: 5, cache_read: nil, cache_write: nil) }
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
