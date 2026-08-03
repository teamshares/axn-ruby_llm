# frozen_string_literal: true

require "ruby_llm"
require "axn"

require_relative "ruby_llm/version"
require_relative "ruby_llm/ask"

module Axn
  module RubyLLM
    include Axn::Mountable
    extend Axn::Configurable
    extend Axn::Tools::AdapterRoots

    setting :default_model, default: "gpt-4o-mini"
    setting :enabled, default: true
    setting :error_headline, default: "LLM request failed"

    # `Axn::Tools::AdapterRoots` (extended above) declares `tool_roots` with `default: []`; re-declare
    # it (core's `setting` is last-wins) to ship the shared agent-tools dir as the default, so any Axn
    # living under `app/agent_tools` is exposed as a `:ruby_llm` tool out of the box. It's the same dir
    # axn-mcp defaults to, so one Axn there is authored once and surfaces on both. The re-declaration
    # keeps AdapterRoots' broad-path validation (no widening a root to `app/`/`actions`/`.`/`..`).
    setting :tool_roots, default: ["agent_tools"], validate: ->(value) { Axn::Tools::AdapterRoots.validate!(value) }

    # Register this module as the `:ruby_llm` adapter AND its config source (PRO-2948): the registry
    # reads `Axn::RubyLLM.config.tool_roots` off the source to grant directory-based membership.
    Axn.register_tool_adapter(:ruby_llm, self)

    mount_axn :ask, Ask

    class << self
      # `enabled` accepts a Boolean OR a callable — the documented production-gating idiom is
      # `c.enabled = -> { Rails.env.production? }`. axn's Configurable used to invoke an assigned
      # callable on read via `callable: true`; that kwarg was removed upstream (PRO-3017) and an
      # assigned Proc is now returned as-is, so resolve it here. Without this the DSL-generated
      # `config.enabled?` is `!!some_proc` — always true — and production gating dies silently.
      # This (`Axn::RubyLLM.enabled?`), NOT `config.enabled?`, is the supported reader.
      def enabled?
        value = config.enabled
        value.respond_to?(:call) ? !!value.call : !!value
      end

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
