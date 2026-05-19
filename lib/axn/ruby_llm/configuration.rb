# frozen_string_literal: true

module Axn
  module RubyLLM
    class Configuration
      DEFAULT_MODEL = "gpt-4o-mini"

      attr_accessor :default_model, :enabled, :opentelemetry

      def initialize
        @default_model = DEFAULT_MODEL
        @enabled = true
        @opentelemetry = :auto
      end

      def enabled?
        enabled.respond_to?(:call) ? !!enabled.call : !!enabled
      end
    end
  end
end
