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

        def trace_ask(model:, json:, &)
          t = tracer
          return yield unless t

          t.in_span("axn_ruby_llm.ask", attributes: { "llm.model" => model, "llm.json_mode" => json }, &)
        end
      end
    end
  end
end
