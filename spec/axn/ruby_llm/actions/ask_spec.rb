# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::Actions::Ask do
  subject(:result) { described_class.call(**params) }

  let(:prompt) { "Summarize this thread." }
  let(:params) { { prompt: } }

  let(:llm_response_content) { "Here is the summary." }
  let(:llm_response) { instance_double(RubyLLM::Message, content: llm_response_content) }
  let(:chat_instance) { instance_double(RubyLLM::Chat) }

  before do
    allow(RubyLLM).to receive(:chat).and_return(chat_instance)
    allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
    allow(chat_instance).to receive(:with_params).and_return(chat_instance)
    allow(chat_instance).to receive(:ask).with(prompt).and_return(llm_response)
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

  context "when the daily token limit is hit" do
    before do
      allow(chat_instance).to receive(:ask).and_raise(StandardError.new("tokens_usage_based per day limit exceeded"))
    end

    it "fails with a rate limit message" do
      expect(result).not_to be_ok
      expect(result.error).to include("Daily token limit reached")
      expect(result.error).to include("tokens_usage_based per day limit exceeded")
    end

    context "with a custom rate_limit_phrase" do
      before do
        Axn::RubyLLM.configure { |c| c.rate_limit_phrase = "rate limit exceeded" }
        allow(chat_instance).to receive(:ask).and_raise(StandardError.new("rate limit exceeded for this org"))
      end

      it "respects the configured phrase" do
        expect(result).not_to be_ok
        expect(result.error).to include("Daily token limit reached")
      end
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
end
