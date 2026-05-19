# frozen_string_literal: true

module Axn
  module RubyLLM
    class Configuration
      DEFAULT_MODEL = "gpt-4o-mini"

      attr_accessor :default_model

      def initialize
        @default_model = DEFAULT_MODEL
      end
    end
  end
end
