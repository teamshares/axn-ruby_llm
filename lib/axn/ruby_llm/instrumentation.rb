# frozen_string_literal: true

module Axn
  module RubyLLM
    # Auto-installs thoughtbot's opentelemetry-instrumentation-ruby_llm patches
    # so the host app doesn't have to add `c.use 'OpenTelemetry::Instrumentation::RubyLLM'`
    # to their OpenTelemetry::SDK.configure block. Idempotent.
    module Instrumentation
      class << self
        def maybe_install
          return if @installed
          return unless install?

          require "opentelemetry/instrumentation/ruby_llm"
          ::OpenTelemetry::Instrumentation::RubyLLM::Instrumentation.instance.install({})
          @installed = true
        end

        def reset!
          @installed = nil
        end

        private

        def install?
          case Axn::RubyLLM.configuration.opentelemetry
          when :auto then defined?(::OpenTelemetry::SDK)
          else !!Axn::RubyLLM.configuration.opentelemetry
          end
        end
      end
    end
  end
end
