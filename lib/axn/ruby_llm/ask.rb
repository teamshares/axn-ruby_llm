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

      exposes :response
      exposes :raw_message
      exposes :input_tokens, allow_nil: true
      exposes :output_tokens, allow_nil: true
      exposes :cache_read_tokens, allow_nil: true
      exposes :cache_write_tokens, allow_nil: true
      exposes :cost, allow_nil: true
      exposes :cost_breakdown, allow_nil: true
      exposes :stubbed, type: :boolean, default: false

      StubMessage = Data.define(:content, :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :model_id)

      error prefix: "LLM request failed: "
      error "Failed to parse JSON from LLM response", if: JSON::ParserError

      before do
        if disabled?
          exposures = stubbed_exposures
          record_otel_attributes!(
            input_tokens: exposures[:input_tokens],
            output_tokens: exposures[:output_tokens],
            cost: exposures[:cost],
            response_model: nil,
            stubbed: true,
          )
          done!("disabled - returning stubbed values", **exposures)
        end
      end

      def call
        expose(
          response: parsed_response,
          raw_message: llm_response,
          input_tokens: llm_response.input_tokens,
          output_tokens: llm_response.output_tokens,
          cache_read_tokens: llm_response.cache_read_tokens,
          cache_write_tokens: llm_response.cache_write_tokens,
          cost_breakdown:,
          cost: cost_breakdown&.total,
          stubbed: false,
        )
        record_otel_attributes!(
          input_tokens: llm_response.input_tokens,
          output_tokens: llm_response.output_tokens,
          cost: cost_breakdown&.total,
          response_model: llm_response.model_id,
          stubbed: false,
        )
      rescue ::RubyLLM::RateLimitError => e
        fail! "Rate limit reached: #{e.message}"
      end

      private

      def disabled? = !Axn::RubyLLM.configuration.enabled?

      def stubbed_exposures
        content = schema || json ? { "stubbed" => true } : "stubbed response value"
        {
          response: content,
          raw_message: StubMessage.new(content:, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, model_id: "stubbed"),
          input_tokens: 0,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          cost: 0.0,
          cost_breakdown: nil,
          stubbed: true,
        }
      end

      def parsed_response
        if schema
          # with_schema makes RubyLLM parse the response into a Hash on success
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
      rescue ::RubyLLM::ModelNotFoundError
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

      def record_otel_attributes!(input_tokens:, output_tokens:, cost:, response_model:, stubbed:)
        return unless defined?(::OpenTelemetry::Trace)

        span = ::OpenTelemetry::Trace.current_span
        return unless span&.context&.valid?

        span.set_attribute("gen_ai.request.model", resolved_model) if resolved_model
        span.set_attribute("gen_ai.response.model", response_model) if response_model
        span.set_attribute("gen_ai.usage.input_tokens", input_tokens) if input_tokens
        span.set_attribute("gen_ai.usage.output_tokens", output_tokens) if output_tokens
        span.set_attribute("gen_ai.usage.cost", cost) if cost
        span.set_attribute("axn.ruby_llm.stubbed", stubbed) unless stubbed.nil?
      rescue StandardError
        # never let telemetry break the action
      end
    end
  end
end
