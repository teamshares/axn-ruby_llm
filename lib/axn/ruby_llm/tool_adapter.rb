# frozen_string_literal: true

module Axn
  module RubyLLM
    # Wraps any Axn as a ::RubyLLM::Tool: schema, name, and description are read straight off the
    # Axn's own declared contract (`input_schema` / `resolved_axn_name` / `description`, from axn's
    # core reflection), so a tool needs no adapter-specific mixin to be wrapped.
    #
    # `halt_after:` / `provider_params:` / `render_as:` can be declared once on the Axn itself via
    # core's extension-metadata registry (`axn_class.set_extension_metadata(:ruby_llm, halt_after:
    # true, provider_params: {...}, render_as: :text)`) and are overridable per-call via the matching
    # `wrap` keyword.
    module ToolAdapter
      NOT_SET = Object.new.freeze

      class << self
        def wrap(axn_class, halt_after: nil, provider_params: nil, render_as: nil, ambient_context: NOT_SET)
          metadata = axn_class.extension_metadata(:ruby_llm)
          tool_class = build_tool_class(
            axn_class,
            halt_after: halt_after.nil? ? metadata.fetch(:halt_after, false) : halt_after,
            provider_params: provider_params.nil? ? metadata.fetch(:provider_params, {}) : provider_params,
            render_as: render_as.nil? ? metadata.fetch(:render_as, :structured) : render_as,
            ambient_context:,
          )

          ambient_context.equal?(NOT_SET) ? tool_class : tool_class.new
        end

        private

        def build_tool_class(axn_class, halt_after:, provider_params:, render_as:, ambient_context:)
          Class.new(::RubyLLM::Tool) do
            description(axn_class.description) if axn_class.description
            params(axn_class.input_schema)
            with_params(**provider_params) if provider_params.any?

            define_method(:name) { axn_class.resolved_axn_name }

            define_method(:execute) do |**args|
              call_args = ambient_context.equal?(NOT_SET) ? args : args.merge(ambient_context:)
              result = axn_class.call(**call_args)

              next({ error: result.error }) unless result.ok?

              payload = render_as == :text ? result.message : Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)
              halt_after ? halt(payload) : payload
            end
          end
        end
      end
    end

    class << self
      def wrap(...)
        ToolAdapter.wrap(...)
      end
    end
  end
end
