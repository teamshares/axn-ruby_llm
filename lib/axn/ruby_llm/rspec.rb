# frozen_string_literal: true

require "axn-ruby_llm"

module Axn
  module RubyLLM
    module RSpec
      module Helpers
        # Stubs RubyLLM so that Actions::Ask returns a canned response.
        #
        # Usage in a spec:
        #   stub_axn_ruby_llm(response: "Here is a summary.")
        #   stub_axn_ruby_llm(response: { "key" => "value" })  # auto-JSON-serialized for json: true calls
        #
        # Returns the chat instance double for further assertions if needed.
        def stub_axn_ruby_llm(response:, model: nil)
          content = response.is_a?(Hash) ? response.to_json : response.to_s
          llm_message = instance_double(::RubyLLM::Message, content:)
          chat_instance = instance_double(::RubyLLM::Chat)

          if model
            allow(::RubyLLM).to receive(:chat).with(model:).and_return(chat_instance)
          else
            allow(::RubyLLM).to receive(:chat).and_return(chat_instance)
          end

          allow(chat_instance).to receive(:with_instructions).and_return(chat_instance)
          allow(chat_instance).to receive(:with_params).and_return(chat_instance)
          allow(chat_instance).to receive(:ask).and_return(llm_message)

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
