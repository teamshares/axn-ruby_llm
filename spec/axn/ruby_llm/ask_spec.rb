# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::Ask do
  subject(:result) { described_class.call(**params) }

  let(:prompt) { "Summarize this thread." }
  let(:params) { { prompt: } }

  let(:llm_response_content) { "Here is the summary." }
  let(:llm_input_tokens) { 12 }
  let(:llm_output_tokens) { 34 }
  let(:llm_model_id) { "gpt-4o-mini" }
  let(:llm_cost) { instance_double(RubyLLM::Cost, total: 0.00056) }
  let(:llm_model_info) { instance_double("RubyLLM::Model") }
  let(:llm_response) do
    instance_double(
      RubyLLM::Message,
      content: llm_response_content,
      input_tokens: llm_input_tokens,
      output_tokens: llm_output_tokens,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      model_id: llm_model_id,
    )
  end
  let(:chat_instance) { instance_double(RubyLLM::Chat) }

  before do
    allow(RubyLLM).to receive(:chat).and_return(chat_instance)
    allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
    allow(chat_instance).to receive(:with_params).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).with(prompt).and_return(llm_response)
    allow(RubyLLM.models).to receive(:find).with(llm_model_id).and_return(llm_model_info)
    allow(llm_response).to receive(:cost).with(model: llm_model_info).and_return(llm_cost)
  end

  after do
    Axn::RubyLLM.reset_configuration!
  end

  context "with default params (json: false)" do
    it "returns raw text response" do
      expect(result).to be_ok
      expect(result.response).to eq("Here is the summary.")
    end

    it "does not configure JSON response format" do
      expect(chat_instance).not_to receive(:with_params)
      result
    end

    it "exposes raw_message" do
      expect(result.raw_message).to eq(llm_response)
    end
  end

  context "with json: true" do
    let(:llm_response_content) { { "answer" => "42" }.to_json }
    let(:params) { { prompt:, json: true } }

    it "returns parsed JSON response" do
      expect(result).to be_ok
      expect(result.response).to eq({ "answer" => "42" })
    end

    it "configures chat with JSON response format" do
      expect(chat_instance).to receive(:with_params).with(response_format: { type: "json_object" })
      result
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
      expect(RubyLLM).to receive(:chat).with(model: Axn::RubyLLM.configuration.default_model)
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

    it "calls with_params for temperature" do
      expect(chat_instance).to receive(:with_params).with(temperature: 0.7).and_return(chat_instance)
      result
    end
  end

  context "with a schema" do
    let(:schema_class) { Class.new }
    let(:llm_response_content) { { "company_id" => 7, "confidence" => 0.9 } }
    let(:params) { { prompt:, schema: schema_class } }

    before do
      allow(chat_instance).to receive(:with_schema).with(schema_class).and_return(chat_instance)
    end

    it "configures chat with the schema and returns the parsed Hash" do
      expect(chat_instance).to receive(:with_schema).with(schema_class).and_return(chat_instance)
      expect(result).to be_ok
      expect(result.response).to eq({ "company_id" => 7, "confidence" => 0.9 })
    end

    it "does not also force JSON response_format params" do
      expect(chat_instance).not_to receive(:with_params).with(response_format: anything)
      result
    end

    context "when the LLM returns non-JSON despite the schema" do
      let(:llm_response_content) { "not valid json {broken" }

      it "fails with a schema-specific error" do
        expect(result).not_to be_ok
        expect(result.error).to include("Schema response was not valid JSON")
      end
    end

    context "with json: true also set" do
      let(:params) { { prompt:, schema: schema_class, json: true } }

      it "schema wins; response is the Hash, no manual JSON.parse path" do
        expect(result).to be_ok
        expect(result.response).to eq({ "company_id" => 7, "confidence" => 0.9 })
      end

      it "does not configure with_params(response_format:)" do
        expect(chat_instance).not_to receive(:with_params).with(response_format: anything)
        result
      end
    end
  end

  context "when the provider raises a rate limit error" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(RubyLLM::RateLimitError.new("429 Too Many Requests"))
    end

    it "fails with a rate limit message" do
      expect(result).not_to be_ok
      expect(result.error).to include("Rate limit reached")
      expect(result.error).to include("429 Too Many Requests")
    end
  end

  context "when a generic error occurs" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(StandardError.new("Network timeout"))
    end

    it "fails with the error prefix" do
      expect(result).not_to be_ok
      expect(result.error).to eq("LLM request failed: Network timeout")
    end
  end

  context "when JSON parsing fails" do
    let(:llm_response_content) { "invalid json {broken" }
    let(:params) { { prompt:, json: true } }

    it "fails with the JSON parse error message" do
      expect(result).not_to be_ok
      expect(result.error).to eq("Failed to parse JSON from LLM response")
    end
  end

  describe "token counts and cost" do
    it "exposes input_tokens and output_tokens from the LLM response" do
      expect(result.input_tokens).to eq(12)
      expect(result.output_tokens).to eq(34)
      expect(result.cache_read_tokens).to be_nil
      expect(result.cache_write_tokens).to be_nil
      expect(result.prompt_tokens).to eq(12) # input only, no cache tokens
    end

    it "exposes total cost as a Float via cost" do
      expect(result.cost).to eq(0.00056)
    end

    it "exposes the full Cost struct via cost_breakdown" do
      expect(result.cost_breakdown).to eq(llm_cost)
    end

    context "when RubyLLM has no pricing for the model" do
      before do
        allow(RubyLLM.models).to receive(:find).with(llm_model_id).and_return(nil)
      end

      it "still succeeds with nil cost fields" do
        expect(result).to be_ok
        expect(result.cost).to be_nil
        expect(result.cost_breakdown).to be_nil
      end

      it "still exposes token counts" do
        expect(result.input_tokens).to eq(12)
        expect(result.output_tokens).to eq(34)
        expect(result.prompt_tokens).to eq(12)
      end
    end

    context "when RubyLLM.models.find raises ModelNotFoundError" do
      before do
        allow(RubyLLM.models).to receive(:find).with(llm_model_id).and_raise(RubyLLM::ModelNotFoundError.new("registry boom"))
      end

      it "treats missing model info as nil cost" do
        expect(result).to be_ok
        expect(result.cost).to be_nil
        expect(result.cost_breakdown).to be_nil
      end
    end

    context "when RubyLLM.models.find raises an unexpected StandardError" do
      before do
        allow(RubyLLM.models).to receive(:find).with(llm_model_id).and_raise(StandardError.new("registry explosion"))
      end

      it "propagates as an LLM request failure" do
        expect(result).not_to be_ok
        expect(result.error).to eq("LLM request failed: registry explosion")
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

      it "exposes a stub response and stubbed flag" do
        expect(result.response).to eq("stubbed response value")
        expect(result.stubbed).to eq(true)
        expect(result.raw_message.content).to eq("stubbed response value")
        expect(result.raw_message.model_id).to eq("stubbed")
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

    context "with json: true while disabled" do
      let(:params) { { prompt:, json: true } }
      before { Axn::RubyLLM.configure { |c| c.enabled = false } }

      it "stubs with a non-empty Hash" do
        expect(result.response).to eq({ "stubbed" => true })
        expect(result.stubbed).to eq(true)
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
end

RSpec.describe "Axn::RubyLLM::Ask OTel attribute enrichment" do
  let(:prompt) { "Summarize this." }
  let(:span_context) { double("SpanContext", valid?: true) }
  let(:span) do
    double("Span", context: span_context).tap do |s|
      allow(s).to receive(:set_attribute)
    end
  end

  let(:llm_response) do
    instance_double(RubyLLM::Message,
                    content: "summary",
                    input_tokens: 10,
                    output_tokens: 5,
                    cache_read_tokens: nil,
                    cache_write_tokens: nil,
                    model_id: "gpt-4o-mini")
  end
  let(:chat_instance) { instance_double(RubyLLM::Chat) }

  # Stub axn's own OTel tracer so that stub_const("OpenTelemetry::Trace") doesn't
  # cause axn's executor to call OpenTelemetry.tracer_provider on a bare module.
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
    allow(chat_instance).to receive(:with_params).and_return(chat_instance)
    allow(chat_instance).to receive(:with_schema).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).and_return(llm_response)
    allow(RubyLLM.models).to receive(:find).and_return(nil)
    allow(llm_response).to receive(:cost).and_return(nil)
    allow(Axn::Internal::Tracing).to receive(:tracer).and_return(fake_axn_tracer)
    stub_const("OpenTelemetry::Trace", Module.new)
    allow(OpenTelemetry::Trace).to receive(:current_span).and_return(span)
  end

  after { Axn::RubyLLM.reset_configuration! }

  it "sets gen_ai and cost attributes on the current span for a normal call" do
    Axn::RubyLLM.ask(prompt:)
    expect(span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o-mini")
    expect(span).to have_received(:set_attribute).with("gen_ai.response.model", "gpt-4o-mini")
    expect(span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 10)
    expect(span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 5)
    expect(span).to have_received(:set_attribute).with("axn.ruby_llm.stubbed", false)
  end

  it "sets cost attribute when cost is available" do
    model_info = instance_double("RubyLLM::Model")
    cost_struct = instance_double(RubyLLM::Cost, total: 0.0007)
    allow(RubyLLM.models).to receive(:find).and_return(model_info)
    allow(llm_response).to receive(:cost).with(model: model_info).and_return(cost_struct)
    Axn::RubyLLM.ask(prompt:)
    expect(span).to have_received(:set_attribute).with("gen_ai.usage.cost", 0.0007)
  end

  context "when disabled (stubbed path)" do
    before { Axn::RubyLLM.configure { |c| c.enabled = false } }

    it "sets request model, zero tokens, zero cost, and stubbed=true; no response model" do
      Axn::RubyLLM.ask(prompt:)
      expect(span).to have_received(:set_attribute).with("gen_ai.request.model", "gpt-4o-mini")
      expect(span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 0)
      expect(span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 0)
      expect(span).to have_received(:set_attribute).with("gen_ai.usage.cost", 0.0)
      expect(span).to have_received(:set_attribute).with("axn.ruby_llm.stubbed", true)
      expect(span).not_to have_received(:set_attribute).with("gen_ai.response.model", anything)
    end
  end

  context "when OTel is not loaded" do
    before { hide_const("OpenTelemetry::Trace") }

    it "still succeeds and makes no attribute calls" do
      result = Axn::RubyLLM.ask(prompt:)
      expect(result).to be_ok
      expect(span).not_to have_received(:set_attribute)
    end
  end

  context "when there is no active span (context not valid)" do
    let(:span_context) { double("SpanContext", valid?: false) }

    it "still succeeds and makes no attribute calls" do
      result = Axn::RubyLLM.ask(prompt:)
      expect(result).to be_ok
    end
  end

  context "when set_attribute raises" do
    before { allow(span).to receive(:set_attribute).and_raise(StandardError, "span closed") }

    it "still succeeds" do
      expect(Axn::RubyLLM.ask(prompt:)).to be_ok
    end
  end
end
