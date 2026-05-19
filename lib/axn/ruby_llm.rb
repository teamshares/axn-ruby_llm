# frozen_string_literal: true

require "axn"
require "ruby_llm"

require_relative "ruby_llm/version"
require_relative "ruby_llm/configuration"
require_relative "ruby_llm/instrumentation"
require_relative "ruby_llm/ask"

module Axn
  module RubyLLM
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def reset_configuration!
        @configuration = nil
      end

      def ask(**) = Ask.call(**)
      def ask!(**) = Ask.call!(**)
    end
  end
end
