# frozen_string_literal: true

require "ruby_llm"
require "axn"

# Register the :ruby_llm tool adapter with axn core's process-global registry (PRO-2921) so
# `Axn.tools_for(:ruby_llm)` is legal and any Axn can opt in via `tool :ruby_llm` or a
# `configure(:ruby_llm)` bag. Idempotent (the registry backs on a Set).
Axn.register_tool_adapter(:ruby_llm)

require_relative "ruby_llm/version"
require_relative "ruby_llm/ask"

module Axn
  module RubyLLM
    include Axn::Mountable
    extend Axn::Configurable

    setting :default_model, default: "gpt-4o-mini"
    setting :enabled, default: true, callable: true
    setting :error_headline, default: "LLM request failed"

    mount_axn :ask, Ask

    class << self
      # DEPRECATED backward-compatible aliases for the pre-DSL API. The
      # Axn::Configurable DSL standardizes on `.config` / `reset_config!`.
      # These keep older callers working but emit a deprecation warning and
      # are scheduled for removal in the next minor version (see DEPRECATIONS.md).
      def configuration
        _warn_deprecated_alias("Axn::RubyLLM.configuration", "Axn::RubyLLM.config")
        config
      end

      def reset_configuration!
        _warn_deprecated_alias("Axn::RubyLLM.reset_configuration!", "Axn::RubyLLM.reset_config!")
        reset_config!
      end

      private

      def _warn_deprecated_alias(old, new)
        warn(
          "[axn-ruby_llm] DEPRECATION: #{old} is deprecated and will be removed in the next minor version; use #{new} instead.",
          category: :deprecated,
          uplevel: 2,
        )
      end
    end
  end
end

require_relative "ruby_llm/tool_adapter"
