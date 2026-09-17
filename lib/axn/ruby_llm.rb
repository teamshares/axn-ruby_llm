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
    extend Axn::Tools::AdapterSerialization

    setting :default_model, default: "gpt-4o-mini"
    setting :enabled, default: true
    setting :error_headline, default: "LLM request failed"

    # `Axn::Tools::AdapterRoots` (extended above) declares `tool_roots` with core's conservative
    # `default: []`; `tool_roots_default` re-declares it to ship the shared agent-tools dir, so any Axn
    # living under `app/agent_tools` is exposed as a `:ruby_llm` tool out of the box. It's the same dir
    # axn-mcp defaults to, so one Axn there is authored once and surfaces on both. Going through
    # `tool_roots_default` rather than a hand-written `setting` keeps AdapterRoots' broad-path
    # validation (no widening a root to `app/`/`actions`/`.`/`..`) without hand-copying its lambda, and
    # validates the default EAGERLY at gem load instead of at the registry's first read.
    tool_roots_default %w[agent_tools]

    # Register this module as the `:ruby_llm` adapter AND its config source (PRO-2948): the registry
    # reads `Axn::RubyLLM.config.tool_roots` off the source to grant directory-based membership.
    Axn::Tools.register_adapter(:ruby_llm, self)

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
    end
  end
end

require_relative "ruby_llm/tool_adapter"
