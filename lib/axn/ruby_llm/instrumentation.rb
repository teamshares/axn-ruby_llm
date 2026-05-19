# frozen_string_literal: true

module Axn
  module RubyLLM
    module Instrumentation
      class << self
        def tracer
          return nil unless defined?(OpenTelemetry)

          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn-ruby_llm", Axn::RubyLLM::VERSION)
        end

        def trace_ask(model:, json:)
          t = tracer
          return yield unless t

          t.in_span("axn_ruby_llm.ask", attributes: { "llm.model" => model, "llm.json_mode" => json }) do |span|
            yield.tap { |message| record_usage(span, message) }
          end
        end

        private

        def record_usage(span, message)
          return unless message.respond_to?(:input_tokens)

          span.set_attribute("llm.input_tokens", message.input_tokens) if message.input_tokens
          span.set_attribute("llm.output_tokens", message.output_tokens) if message.output_tokens
        rescue StandardError
          # Instrumentation must never break the call
        end
      end
    end
  end
end
