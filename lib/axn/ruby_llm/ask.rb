# frozen_string_literal: true

module Axn
  module RubyLLM
    class Ask
      include Axn

      expects :prompt
      expects :json, type: :boolean, default: false
      expects :schema, optional: true
      expects :model, optional: true
      expects :system_prompt, optional: true
      expects :temperature, optional: true

      exposes :response, allow_blank: true
      exposes :raw_message, allow_nil: true
      exposes :input_tokens, allow_nil: true
      exposes :output_tokens, allow_nil: true
      exposes :cost, allow_nil: true
      exposes :cost_breakdown, allow_nil: true
      exposes :stubbed, type: :boolean, default: false

      error prefix: "LLM request failed: "
      error "Failed to parse JSON from LLM response", if: JSON::ParserError

      def call
        Instrumentation.maybe_install
        return expose_stub if disabled?

        expose(
          response: parsed_response,
          raw_message: llm_response,
          input_tokens: llm_response.input_tokens,
          output_tokens: llm_response.output_tokens,
          cost_breakdown:,
          cost: cost_breakdown&.total,
          stubbed: false,
        )
      rescue ::RubyLLM::RateLimitError => e
        fail! "Rate limit reached: #{e.message}"
      end

      private

      def disabled? = !Axn::RubyLLM.configuration.enabled?

      def expose_stub
        info "LLM call disabled; returning stub response"
        expose(
          response: schema || json ? {} : "",
          raw_message: nil,
          input_tokens: 0,
          output_tokens: 0,
          cost: 0.0,
          cost_breakdown: nil,
          stubbed: true,
        )
      end

      def parsed_response
        if schema
          return llm_response.content if llm_response.content.is_a?(Hash)

          fail! "Schema response was not valid JSON"
        end
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

      memo def llm_response = chat.ask(prompt)

      memo def chat
        ::RubyLLM.chat(model: resolved_model).tap do |c|
          c.with_instructions(system_prompt) if system_prompt
          c.with_schema(schema) if schema
          c.with_params(response_format: { type: "json_object" }) if json && !schema
          c.with_params(temperature:) if temperature
        end
      end

      def resolved_model
        model || Axn::RubyLLM.configuration.default_model
      end
    end
  end
end
