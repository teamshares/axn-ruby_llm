# frozen_string_literal: true

require "ruby_llm"
require "axn"

require_relative "ruby_llm/version"
require_relative "ruby_llm/ask"

module Axn
  module RubyLLM
    include Axn::Mountable
    extend Axn::Configurable

    setting :default_model, default: "gpt-4o-mini"
    setting :enabled, default: true, callable: true

    mount_axn :ask, Ask

    class << self
      # Backward-compatible aliases for the pre-DSL API. The Axn::Configurable
      # DSL standardizes on `.config` / `reset_config!`; these keep older callers
      # that used `.configuration` / `reset_configuration!` working.
      def configuration
        config
      end

      def reset_configuration!
        reset_config!
      end
    end
  end
end
