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
        #   stub_axn_ruby_llm("...", thinking_tokens: 300, server_tool_use: { "web_search_requests" => 1 })
        #   stub_axn_ruby_llm("partial", finish_reason: :max_tokens)  # exercise Ask's truncation failure
        #   stub_axn_ruby_llm(response: "...")               # keyword form still works
        #
        # Returns the chat instance double for further assertions if needed.
        # rubocop:disable-next Metrics/ParameterLists -- one optional keyword per stubbable usage field
        def stub_axn_ruby_llm(positional_response = UNSET, response: UNSET, model: nil, schema: nil,
                              input_tokens: nil, output_tokens: nil, cache_read_tokens: nil,
                              cache_write_tokens: nil, thinking_tokens: nil, server_tool_use: nil,
                              cost: nil, finish_reason: :stop)
          response = positional_response unless positional_response.equal?(UNSET)
          raise ArgumentError, "stub_axn_ruby_llm requires a response (positionally or as `response:`)" if response.equal?(UNSET)

          resolved_model_id = model || Axn::RubyLLM.config.default_model
          llm_message = _stub_axn_ruby_llm_message(response, resolved_model_id, schema:, finish_reason:)
          tokens = ::RubyLLM::Tokens.new(input: input_tokens, output: output_tokens, cache_read: cache_read_tokens,
                                         cache_write: cache_write_tokens, thinking: thinking_tokens, server_tool_use:)
          _stub_axn_ruby_llm_chat(model, llm_message, tokens:, cost:)
        end

        private

        # `content` mirrors real ::RubyLLM::Message#content (a read-only String, JSON text when
        # `schema:` is set); `parsed` mirrors #parsed (the Hash `schema:` callers actually want back
        # via Ask's `parsed_response`, which reads `.parsed` -- not `.content` -- once schema is set).
        # finish_reason/max_tokens?/content_filtered? mirror the real predicates, so a helper-stubbed
        # call goes through Ask's truncation/filter check like a real one.
        def _stub_axn_ruby_llm_message(response, model_id, schema:, finish_reason:)
          content = schema ? response.to_json : response.to_s
          parsed = schema ? response : nil
          instance_double(::RubyLLM::Message, content:, parsed:, model: model_id, finish_reason:,
                                              max_tokens?: finish_reason == :max_tokens,
                                              content_filtered?: finish_reason == :content_filter)
        end

        def _stub_axn_ruby_llm_chat(model, llm_message, tokens:, cost:)
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
          # A real ::RubyLLM::Tokens (a plain value object), not a double, so new ledger fields read as nil
          # instead of tripping a verifying double.
          allow(chat_instance).to receive(:tokens).and_return(tokens)
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
