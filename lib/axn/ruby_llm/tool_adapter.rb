# frozen_string_literal: true

module Axn
  module RubyLLM
    # Namespaced per-class config (axn's `Axn::Configurable`, PRO-2880): any Axn — with no
    # adapter-specific mixin required — can declare `configure(:ruby_llm) { |c| c.halt_after = true }`
    # to set these per-class, alongside e.g. `configure(:mcp) { ... }` for a different adapter on the
    # same class, without the two colliding. `wrap` resolves them via `resolve_override_for`, which
    # falls back to this module's own global `config` (`Axn::RubyLLM.configure { |c| ... }`) and then
    # to each setting's default — the same class-override-then-global-then-default chain a flat
    # `overridable: true` accessor would give a single-adapter consumer.
    config_namespace :ruby_llm
    setting :halt_after, default: false, overridable: true
    setting :provider_params, default: {}, overridable: true
    setting :render_as, default: :structured, one_of: %i[structured text], overridable: true

    # Wraps any Axn as a ::RubyLLM::Tool: schema, name, and description are read straight off the
    # Axn's own declared contract (`input_schema` / `resolved_axn_name` / `description`, from axn's
    # core reflection), so a tool needs no adapter-specific mixin to be wrapped.
    module ToolAdapter
      NOT_SET = Object.new.freeze

      class << self
        def wrap(axn_class, halt_after: nil, provider_params: nil, render_as: nil, ambient_context: NOT_SET)
          tool_class = build_tool_class(
            axn_class,
            halt_after: halt_after.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :halt_after) : halt_after,
            provider_params: provider_params.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :provider_params) : provider_params,
            render_as: render_as.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :render_as) : render_as,
            ambient_context:,
          )

          ambient_context.equal?(NOT_SET) ? tool_class : tool_class.new
        end

        private

        def build_tool_class(axn_class, halt_after:, provider_params:, render_as:, ambient_context:)
          # Core's canonical, provider-safe tool_name (PRO-2921): strips configured leading prefixes,
          # snake_cases with single underscores, restricts to [a-z0-9_], and is never blank (anonymous
          # -> "tool"). Replaces the old crude sanitize_tool_name gsub, whose namespaced output mangled
          # word boundaries (agenttools__listcompanies). The same Axn class now wraps to the same name
          # across every adapter -- Axn::MCP.wrap included -- which is the whole author-once point.
          tool_name = axn_class.tool_name
          input_schema = normalize_nullable_types(axn_class.input_schema)
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

              # RubyLLM::Chat#handle_tool_calls only treats a Content/Content::Raw return as-is; any
              # other object (including a plain Hash) gets `#to_s`'d before being sent to the provider
              # -- which for a Hash produces Ruby's inspect syntax (`{"k"=>"v"}`), not JSON. Serialize
              # structured payloads ourselves so the wire form is always valid JSON.
              payload = if render_as == :text
                          result.message
                        else
                          Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs).to_json
                        end
              halt_after ? halt(payload) : payload
            end
          end
        end

        # `allowed_args` deliberately excludes `ambient_context` (core's reflected input_schema never
        # advertises it) — so a smuggled-in `ambient_context:` tool arg (e.g. prompt injection
        # attempting to run this call under a different tenant's context) is rejected by the returned
        # validator rather than reaching `axn_class.call`, where it would silently replace the
        # caller's own ambient context.
        #
        # The value-type check below is deliberately shallow (top-level JSON type only, no nested
        # properties/items/enum/format) — it exists only to catch an obviously wrong-shaped argument
        # (e.g. `name: 123` for a String field) before it reaches Axn's own `expects` validation, which
        # treats an un-`user_facing:` violation as a dev-facing exception (reported, generic message)
        # rather than RubyLLM's clean, recoverable "Invalid tool arguments" response. A property whose
        # allowed JSON type(s) can't be determined (no `type:`/`anyOf`, e.g. an enum-only or untyped
        # field) is never blocked, so this can't reject a value Axn's own contract would accept.
        def tool_argument_validator(input_schema)
          required_args = Array(input_schema[:required]).map(&:to_sym)
          properties = input_schema.fetch(:properties, {})
          allowed_args = properties.keys.map(&:to_sym)

          lambda do |args|
            missing = required_args - args.keys
            next "Invalid tool arguments: missing keyword: #{missing.first}" if missing.any?

            unknown = args.keys - allowed_args
            next "Invalid tool arguments: unknown keyword: #{unknown.first}" if unknown.any?

            mismatch = args.find { |key, value| !schema_value_matches?(properties[key], value) }
            next "Invalid tool arguments: #{mismatch.first} must be a #{json_types_for(properties[mismatch.first]).join(" or ")}" if mismatch

            nil
          end
        end

        JSON_TYPE_PREDICATES = {
          "string" => ->(v) { v.is_a?(String) },
          "integer" => ->(v) { v.is_a?(Integer) },
          "number" => ->(v) { v.is_a?(Numeric) },
          "boolean" => ->(v) { [true, false].include?(v) },
          "object" => ->(v) { v.is_a?(Hash) },
          "array" => ->(v) { v.is_a?(Array) },
          "null" => lambda(&:nil?),
        }.freeze
        private_constant :JSON_TYPE_PREDICATES

        # The property's allowed JSON type(s), or nil when none can be determined (untyped, enum-only,
        # or an anyOf with no member `type:`) — nil means "don't check", never "reject everything".
        def json_types_for(prop)
          return nil unless prop

          return Array(prop[:type]) if prop[:type]
          return prop[:anyOf].flat_map { |member| Array(member[:type]) }.uniq if prop[:anyOf]

          nil
        end

        def schema_value_matches?(prop, value)
          types = json_types_for(prop)
          return true if types.nil? || types.empty?

          types.any? { |type| JSON_TYPE_PREDICATES[type]&.call(value) }
        end

        # axn reflects a nullable/optional field as a JSON Schema array-valued `type`
        # (e.g. `["integer", "null"]`). That's valid JSON Schema and OpenAI/Anthropic consume it
        # fine, but RubyLLM's Gemini converter only recognizes anyOf-form nullability: it does
        # `param_type_for_gemini(type)` with `type.to_s.downcase`, so an array `type` matches no
        # case and falls through to STRING -- silently dropping both the declared type and the
        # nullability. Rewrite every array-valued `type` into the equivalent `anyOf: [{type: ...}]`,
        # which Gemini's `normalize_any_of_schema` collapses back to the real type + nullable, and
        # which the other providers accept unchanged. Purely a wire-shape change: the admitted value
        # set is identical, and the adapter's own validator (json_types_for) already reads anyOf.
        #
        # Builds new Hashes/Arrays throughout rather than mutating -- axn may hand back a memoized
        # input_schema, and mutating it would corrupt every other reader.
        def normalize_nullable_types(node)
          case node
          when Hash
            rebuilt = node.to_h { |key, value| [key, normalize_nullable_types(value)] }
            if rebuilt[:type].is_a?(Array)
              types = rebuilt.delete(:type)
              rebuilt[:anyOf] = types.map { |type| { type: } }
            end
            rebuilt
          when Array
            node.map { |value| normalize_nullable_types(value) }
          else
            node
          end
        end
      end
    end

    class << self
      def wrap(...)
        ToolAdapter.wrap(...)
      end

      # Every Axn registered as a :ruby_llm tool -- via `tool`/`tool :ruby_llm`, residency under a
      # configured tool_path, or a `configure(:ruby_llm)` bag (see Axn::Tools::Registry#member?) --
      # each already wrapped as a ::RubyLLM::Tool, so a consumer builds its whole chat tool list in
      # one call: `chat.with_tools(*Axn::RubyLLM.tools)`. Mirrors the shared GemName.tools contract
      # with Axn::MCP.tools; the same Axn class resolves to the same tool_name across both surfaces.
      def tools
        Axn.tools_for(:ruby_llm).map { |axn| wrap(axn) }
      end
    end
  end
end
