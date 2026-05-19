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
      end
    end

    context "when RubyLLM.models.find raises" do
      before do
        allow(RubyLLM.models).to receive(:find).with(llm_model_id).and_raise(StandardError.new("registry boom"))
      end

      it "treats missing model info as nil cost" do
        expect(result).to be_ok
        expect(result.cost).to be_nil
        expect(result.cost_breakdown).to be_nil
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
  end
end
