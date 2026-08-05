# frozen_string_literal: true

require "axn-ruby_llm"

module Axn
  module RubyLLM
    module RSpec
      module Helpers
        UNSET = Object.new
        private_constant :UNSET

        # Stubs RubyLLM so that Ask returns a canned response. The response can be given
        # positionally (the common case) or as `response:` — both are equivalent.
        #
        # Usage in a spec:
        #   stub_axn_ruby_llm("Here is a summary.")
        #   stub_axn_ruby_llm({ "key" => "value" })          # auto-JSON-serialized for json: true calls
        #   stub_axn_ruby_llm({ "k" => "v" }, schema: MySchema) # Hash passed through unparsed
        #   stub_axn_ruby_llm("...", input_tokens: 100, output_tokens: 50, cost: 0.0023)
        #   stub_axn_ruby_llm("...", cache_read_tokens: 500, cache_write_tokens: 200)
        #   stub_axn_ruby_llm(response: "...")               # keyword form still works
        #
        # Returns the chat instance double for further assertions if needed.
        def stub_axn_ruby_llm(positional_response = UNSET, response: UNSET, model: nil, schema: nil,
                              input_tokens: nil, output_tokens: nil, cache_read_tokens: nil,
                              cache_write_tokens: nil, cost: nil)
          response = positional_response unless positional_response.equal?(UNSET)
          raise ArgumentError, "stub_axn_ruby_llm requires a response (positionally or as `response:`)" if response.equal?(UNSET)

          resolved_model_id = model || Axn::RubyLLM.config.default_model
          llm_message = _stub_axn_ruby_llm_message(response, resolved_model_id, input_tokens, output_tokens,
                                                   cache_read_tokens:, cache_write_tokens:, schema:)
          chat_instance = _stub_axn_ruby_llm_chat(model, llm_message, schema:)
          _stub_axn_ruby_llm_cost(llm_message, resolved_model_id, cost)
          chat_instance
        end

        private

        def _stub_axn_ruby_llm_message(response, model_id, input_tokens, output_tokens, cache_read_tokens:,
                                       cache_write_tokens:, schema:)
          content = if schema
                      response
                    elsif response.is_a?(Hash)
                      response.to_json
                    else
                      response.to_s
                    end
          instance_double(::RubyLLM::Message,
                          content:, input_tokens:, output_tokens:,
                          cache_read_tokens:, cache_write_tokens:, model_id:)
        end

        def _stub_axn_ruby_llm_chat(model, llm_message, schema:)
          chat_instance = instance_double(::RubyLLM::Chat)
          if model
            allow(::RubyLLM).to receive(:chat).with(model:).and_return(chat_instance)
          else
            allow(::RubyLLM).to receive(:chat).and_return(chat_instance)
          end
          %i[with_instructions with_params with_tools].each do |method|
            allow(chat_instance).to receive(method).and_return(chat_instance)
          end
          # Always stub with_schema so specs don't blow up if production code passes schema:
          # even when the helper is called without schema:. Use a tight matcher when schema
          # is known so the stub still validates the correct class is passed.
          if schema
            allow(chat_instance).to receive(:with_schema).with(schema).and_return(chat_instance)
          else
            allow(chat_instance).to receive(:with_schema).and_return(chat_instance)
          end
          allow(chat_instance).to receive(:ask).and_return(llm_message)
          # Ask sums usage across the chat's assistant turns; a stubbed call is single-turn.
          allow(chat_instance).to receive(:messages).and_return([llm_message])
          chat_instance
        end

        def _stub_axn_ruby_llm_cost(llm_message, model_id, cost)
          model_info = instance_double("RubyLLM::Model")
          allow(::RubyLLM.models).to receive(:find).with(model_id).and_return(model_info)
          # Default to zero cost so specs exercise the "model found, cost computed" path.
          # Pass cost: explicitly to assert a specific value.
          cost_total = cost || 0.0
          # tokens?: true — the stubbed message is a billable assistant turn, and Ask's cost_breakdown
          # keeps only token-bearing (tokens?) costs before its one?-vs-aggregate decision.
          cost_struct = instance_double(::RubyLLM::Cost, total: cost_total, tokens?: true)
          allow(llm_message).to receive(:cost).with(model: model_info).and_return(cost_struct)
        end
      end
    end
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.include Axn::RubyLLM::RSpec::Helpers
  end
end
