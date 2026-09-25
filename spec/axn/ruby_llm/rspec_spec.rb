# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::RSpec::Helpers do
  after { Axn::RubyLLM.reset_config! }

  describe "stub_axn_ruby_llm" do
    context "with a plain string response" do
      before { stub_axn_ruby_llm(response: "summary text") }

      it "returns the string response" do
        result = Axn::RubyLLM.ask(prompt: "summarize")
        expect(result).to be_ok
        expect(result.response).to eq("summary text")
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

    context "with every Ask input set" do
      before { stub_axn_ruby_llm("canned", model: "gpt-4o") }

      it "returns the canned response instead of tripping the verifying double" do
        result = Axn::RubyLLM.ask(
          prompt: "hi", model: "gpt-4o", provider: :openai, protocol: :responses, assume_model_exists: true,
          attachments: ["a.pdf"], history: [{ role: :user, content: "earlier" }], system_prompt: "sys",
          cache_system_prompt: true, temperature: 0.1, max_output_tokens: 10, thinking: { effort: :low },
          citations: true, caching: { ttl: "1h" }, compaction: { at: 1000 }, fallbacks: ["gpt-4o-mini"],
          fallback_on: [RubyLLM::ServerError], end_user: "u1", provider_options: { service_tier: "flex" },
          headers: { "x-beta" => "1" }, on_chunk: ->(_chunk) {}, tools: [Class.new(RubyLLM::Tool) { def self.name = "T" }],
          max_tool_calls: 3, provider_tools: { web_search: {} }, tool_options: { calls: :many },
          on_remote_tool_approval: ->(_tool_call) { true }
        )
        expect(result.error).to be_nil
        expect(result.response).to eq("canned")
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
      before { stub_axn_ruby_llm(response: "ok", input_tokens: 100, cache_read_tokens: 500, cache_write_tokens: 200) }

      it "exposes cache_read_tokens, cache_write_tokens, and prompt_tokens sum" do
        result = Axn::RubyLLM.ask(prompt: "hi")
        expect(result.cache_read_tokens).to eq(500)
        expect(result.cache_write_tokens).to eq(200)
        expect(result.prompt_tokens).to eq(800) # 100 + 500 + 200
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

    context "with a positional response (no keyword)" do
      before { stub_axn_ruby_llm("positional summary") }

      it "is equivalent to response:" do
        expect(Axn::RubyLLM.ask(prompt: "summarize").response).to eq("positional summary")
      end
    end

    context "with neither positional nor keyword response" do
      it "raises a clear ArgumentError" do
        expect { stub_axn_ruby_llm }.to raise_error(ArgumentError, /requires a response/)
      end
    end
  end
end
