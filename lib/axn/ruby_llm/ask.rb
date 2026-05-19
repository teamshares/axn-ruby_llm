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
      exposes :input_tokens, allow_nil: true
      exposes :output_tokens, allow_nil: true
      exposes :cost, allow_nil: true
      exposes :cost_breakdown, allow_nil: true

      error prefix: "LLM request failed: "
      error "Failed to parse JSON from LLM response", if: JSON::ParserError

      def call
        expose(
          response: parsed_response,
          raw_message: llm_response,
          input_tokens: llm_response.input_tokens,
          output_tokens: llm_response.output_tokens,
          cost_breakdown:,
          cost: cost_breakdown&.total,
        )
      rescue ::RubyLLM::RateLimitError => e
        fail! "Rate limit reached: #{e.message}"
      end

      private

      def parsed_response
        json ? JSON.parse(llm_response.content) : llm_response.content
      end

      def cost_breakdown
        return nil unless model_info

        llm_response.cost(model: model_info)
      end

      memo def model_info
        ::RubyLLM.models.find(llm_response.model_id)
      rescue StandardError
        nil
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
    end
  end
end
