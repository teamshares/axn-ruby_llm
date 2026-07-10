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
          tool_name = sanitize_tool_name(axn_class.resolved_axn_name)
          input_schema = axn_class.input_schema
          validate_args = tool_argument_validator(input_schema)

          Class.new(::RubyLLM::Tool) do
            description(axn_class.description) if axn_class.description
            params(input_schema)
            with_params(**provider_params) if provider_params.any?

            define_method(:name) { tool_name }

            define_method(:execute) do |**args|
              error = validate_args.call(args)
              next({ error: }) if error

              call_args = ambient_context.equal?(NOT_SET) ? args : args.merge(ambient_context:)
              result = axn_class.call(**call_args)

              next({ error: result.error }) unless result.ok?

              payload = render_as == :text ? result.message : Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)
              halt_after ? halt(payload) : payload
            end
          end
        end

        # `allowed_args` deliberately excludes `ambient_context` (core's reflected input_schema never
        # advertises it) — so a smuggled-in `ambient_context:` tool arg (e.g. prompt injection
        # attempting to run this call under a different tenant's context) is rejected by the returned
        # validator rather than reaching `axn_class.call`, where it would silently replace the
        # caller's own ambient context.
        def tool_argument_validator(input_schema)
          required_args = Array(input_schema[:required]).map(&:to_sym)
          allowed_args = input_schema.fetch(:properties, {}).keys.map(&:to_sym)

          lambda do |args|
            missing = required_args - args.keys
            next "Invalid tool arguments: missing keyword: #{missing.first}" if missing.any?

            unknown = args.keys - allowed_args
            next "Invalid tool arguments: unknown keyword: #{unknown.first}" if unknown.any?

            nil
          end
        end

        # `resolved_axn_name` is a free-form display string (e.g. a namespaced class name like
        # `Some::Nested::Widget`, or the "Anonymous Axn" fallback) — providers require tool names
        # matching `^[a-zA-Z0-9_-]+$`, so it can't be registered as-is (bypassing RubyLLM's own
        # class-name-derived sanitization, since we override `#name` outright).
        def sanitize_tool_name(value)
          sanitized = value.to_s.gsub(/[^a-zA-Z0-9_-]/, "_").downcase
          sanitized.empty? ? "tool" : sanitized
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
