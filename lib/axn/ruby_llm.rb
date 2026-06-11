# frozen_string_literal: true

require "ruby_llm"
require "axn"

require_relative "ruby_llm/version"
require_relative "ruby_llm/configuration"
require_relative "ruby_llm/ask"

module Axn
  module RubyLLM
    include Axn::Mountable

    mount_axn :ask, Ask

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
    end
  end
end
