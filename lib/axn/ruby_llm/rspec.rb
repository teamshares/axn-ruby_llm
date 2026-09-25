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
        #   stub_axn_ruby_llm({ "k" => "v" }, schema: MySchema)  # Hash passed through as `parsed`
        #   stub_axn_ruby_llm("...", input_tokens: 100, output_tokens: 50, cost: 0.0023)
        #     (input_tokens: here is RubyLLM's uncached Tokens#input -- Ask's uncached_input_tokens)
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
          llm_message = _stub_axn_ruby_llm_message(response, resolved_model_id, schema:)
          _stub_axn_ruby_llm_chat(model, llm_message, input_tokens:, output_tokens:,
                                                      cache_read_tokens:, cache_write_tokens:, cost:)
        end

        private

        # `content` mirrors real ::RubyLLM::Message#content (a read-only String, JSON text when
        # `schema:` is set); `parsed` mirrors #parsed (the Hash `schema:` callers actually want back
        # via Ask's `parsed_response`, which reads `.parsed` -- not `.content` -- once schema is set).
        def _stub_axn_ruby_llm_message(response, model_id, schema:)
          content = schema ? response.to_json : response.to_s
          parsed = schema ? response : nil
          instance_double(::RubyLLM::Message, content:, parsed:, model: model_id)
        end

        def _stub_axn_ruby_llm_chat(model, llm_message, input_tokens:, output_tokens:,
                                    cache_read_tokens:, cache_write_tokens:, cost:)
          chat_instance = instance_double(::RubyLLM::Chat)
          if model
            # hash_including: Ask also passes provider:/protocol:/assume_model_exists:/context: when set.
            allow(::RubyLLM).to receive(:chat).with(hash_including(model:)).and_return(chat_instance)
          else
            allow(::RubyLLM).to receive(:chat).and_return(chat_instance)
          end
          # Every public with_* on the real Chat, not a hand-kept list -- Ask forwards whichever inputs
          # the caller set, and the verifying double rejects any method left unstubbed.
          ::RubyLLM::Chat.public_instance_methods(false).grep(/\Awith_/).each do |method|
            allow(chat_instance).to receive(method).and_return(chat_instance)
          end
          allow(chat_instance).to receive(:messages=) # history:
          allow(chat_instance).to receive(:awaiting_approval?).and_return(false) # on_remote_tool_approval:
          allow(chat_instance).to receive(:ask).and_return(llm_message)
          # A stubbed call has no real conversation for transcript_entries to walk -- matches how the
          # disabled/stubbed-config path (Ask#stubbed_exposures) also exposes an empty transcript.
          allow(chat_instance).to receive(:messages).and_return([])
          # Ask reads usage off the chat's own ledger (Chat#tokens / Chat#cost), not per-message --
          # a stubbed call is single-turn, so the ledger is just these values directly.
          allow(chat_instance).to receive(:tokens).and_return(
            instance_double(::RubyLLM::Tokens, input: input_tokens, output: output_tokens,
                                               cache_read: cache_read_tokens, cache_write: cache_write_tokens),
          )
          # Default to zero cost so specs exercise the "cost computed" path.
          # Pass cost: explicitly to assert a specific value.
          allow(chat_instance).to receive(:cost).and_return(instance_double(::RubyLLM::Cost, total: cost || 0.0))
          chat_instance
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
