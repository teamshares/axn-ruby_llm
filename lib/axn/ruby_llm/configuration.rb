# frozen_string_literal: true

module Axn
  module RubyLLM
    class Configuration
      DEFAULT_MODEL = "gpt-4o-mini"

      attr_accessor :default_model, :rate_limit_phrase

      def initialize
        @default_model = DEFAULT_MODEL
        @rate_limit_phrase = "tokens_usage_based per day"
      end
    end
  end
end
