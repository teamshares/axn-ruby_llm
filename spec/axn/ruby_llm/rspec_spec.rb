# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::RSpec::Helpers do
  after { Axn::RubyLLM.reset_configuration! }

  describe "stub_axn_ruby_llm" do
    context "with a plain string response" do
      before { stub_axn_ruby_llm(response: "summary text") }

      it "returns the string response" do
        result = Axn::RubyLLM.ask(prompt: "summarize")
        expect(result).to be_ok
        expect(result.response).to eq("summary text")
      end
    end

    context "with a Hash response (json: true)" do
      before { stub_axn_ruby_llm(response: { "key" => "value" }) }

      it "serializes to JSON for the ask call and parses back" do
        result = Axn::RubyLLM.ask(prompt: "extract", json: true)
        expect(result).to be_ok
        expect(result.response).to eq({ "key" => "value" })
      end
    end

    context "with a schema" do
      let(:schema_class) { Class.new }
      before { stub_axn_ruby_llm(response: { "company_id" => 7 }, schema: schema_class) }

      it "passes the Hash response through unparsed" do
        result = Axn::RubyLLM.ask(prompt: "match", schema: schema_class)
        expect(result).to be_ok
        expect(result.response).to eq({ "company_id" => 7 })
      end
    end

    context "with a model override" do
      before { stub_axn_ruby_llm(response: "ok", model: "gpt-4o") }

      it "routes to the specified model" do
        result = Axn::RubyLLM.ask(prompt: "hi", model: "gpt-4o")
        expect(result).to be_ok
        expect(result.response).to eq("ok")
      end
    end

    context "default cost behavior (no cost: passed)" do
      before { stub_axn_ruby_llm(response: "ok") }

      it "stubs cost as 0.0 (model found path, not nil-cost path)" do
        result = Axn::RubyLLM.ask(prompt: "hi")
        expect(result).to be_ok
        expect(result.cost).to eq(0.0)
        expect(result.cost_breakdown).not_to be_nil
      end
    end

    context "with an explicit cost:" do
      before { stub_axn_ruby_llm(response: "ok", cost: 0.0042) }

      it "exposes the specified cost" do
        result = Axn::RubyLLM.ask(prompt: "hi")
        expect(result.cost).to eq(0.0042)
      end
    end

    context "with cache token params" do
      before { stub_axn_ruby_llm(response: "ok", cache_read_tokens: 500, cache_write_tokens: 200) }

      it "exposes cache_read_tokens and cache_write_tokens" do
        result = Axn::RubyLLM.ask(prompt: "hi")
        expect(result.cache_read_tokens).to eq(500)
        expect(result.cache_write_tokens).to eq(200)
      end
    end

    context "when production code passes schema: but helper is called without schema:" do
      let(:schema_class) { Class.new }
      before { stub_axn_ruby_llm(response: { "x" => 1 }) }

      it "does not raise MessageNotAllowed" do
        expect { Axn::RubyLLM.ask(prompt: "hi", schema: schema_class) }.not_to raise_error
      end
    end

    context "return value" do
      it "returns the chat double for further assertions" do
        chat = stub_axn_ruby_llm(response: "ok")
        expect(chat).to be_an(RSpec::Mocks::InstanceVerifyingDouble)
      end
    end
  end
end
