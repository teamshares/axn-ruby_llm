# frozen_string_literal: true

module Axn
  module RubyLLM
    class Ask
      include Axn

      expects :prompt
      expects :json, type: :boolean, default: false
      expects :model, optional: true
      expects :system_prompt, optional: true
      expects :temperature, optional: true

      exposes :response
      exposes :raw_message

      error prefix: "LLM request failed: "
      error "Failed to parse JSON from LLM response", if: JSON::ParserError

      def call
        expose response: parsed_response, raw_message: llm_response
      rescue StandardError => e
        fail! "Daily token limit reached: #{e.message}" if rate_limited?(e)

        raise e
      end

      private

      def parsed_response
        json ? JSON.parse(llm_response.content) : llm_response.content
      end

      memo def llm_response
        Instrumentation.trace_ask(model: resolved_model, json:) { chat.ask(prompt) }
      end

      memo def chat
        ::RubyLLM.chat(model: resolved_model).tap do |c|
          c.with_instructions(system_prompt) if system_prompt
          c.with_params(response_format: { type: "json_object" }) if json
          c.with_params(temperature:) if temperature
        end
      end

      def resolved_model
        model || Axn::RubyLLM.configuration.default_model
      end

      def rate_limited?(error)
        error.message.include?(Axn::RubyLLM.configuration.rate_limit_phrase)
      end
    end
  end
end
