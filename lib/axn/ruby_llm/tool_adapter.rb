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
    setting :present_as, default: :structured, one_of: %i[structured message], overridable: true
    # `Axn::Tools::AdapterSerialization` (extended onto Axn::RubyLLM in ruby_llm.rb, which is required
    # before this file reopens the module) owns this setting's declaration so the three adapters can't
    # drift on it. `default:` is a required kwarg with no core-picked value on purpose: an LLM-facing
    # adapter is better off shipping an ugly-but-honest rendering than failing the whole tool call, so
    # ruby_llm (like axn-mcp) declares `false`, where axn-openapi's published output contract declares
    # `true`. Must follow `config_namespace` above -- it's an `overridable:` setting.
    declare_reject_opaque_exposed_values! default: false

    # Wraps any Axn as a ::RubyLLM::Tool: schema, name, and description are read straight off the
    # Axn's own declared contract (`input_schema` / `resolved_axn_name` / `description`, from axn's
    # core reflection), so a tool needs no adapter-specific mixin to be wrapped.
    module ToolAdapter
      NOT_SET = Object.new.freeze

      # Client-facing tool-error text when the transport step raises while turning a *successful*
      # result into a response (see the guard in build_tool_class's #execute). Deliberately generic:
      # the actionable detail (class, path) is a gem/tool bug, so it rides on the reported exception
      # (on_exception / logs), not the tool's response — mirroring how axn keeps a failure's detail
      # off the user-facing message, and axn-mcp's Serializer::ADAPTER_FAILURE_MESSAGE.
      ADAPTER_FAILURE_MESSAGE = "The tool could not produce a valid response"

      class << self
        def wrap(axn_class, halt_after: nil, provider_params: nil, present_as: nil, render_as: NOT_SET, ambient_context: NOT_SET)
          validate_present_as_kwargs!(present_as, render_as)

          tool_class = build_tool_class(
            axn_class,
            halt_after: halt_after.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :halt_after) : halt_after,
            provider_params: provider_params.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :provider_params) : provider_params,
            present_as: present_as.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :present_as) : present_as,
            ambient_context:,
          )

          ambient_context.equal?(NOT_SET) ? tool_class : tool_class.new
        end

        private

        # `render_as:` (values :structured/:text) was renamed to `present_as:` (:structured/:message)
        # to unify the knob with axn-mcp's `present_as` (see DEPRECATIONS.md). Pre-1.0, so a leftover
        # `render_as:` is a hard error with a pointer, not a silent shim (an ignored kwarg would quietly
        # revert a caller to :structured). `one_of:` on the setting only guards the config-set path, so
        # validate the `present_as` kwarg here too, pointing render_as's old `:text` value at its rename.
        def validate_present_as_kwargs!(present_as, render_as)
          unless render_as.equal?(NOT_SET)
            raise ArgumentError,
                  "`render_as:` was renamed to `present_as:` and its `:text` value to `:message` " \
                  "(e.g. `Axn::RubyLLM.wrap(..., present_as: :message)`)."
          end

          return if present_as.nil? || %i[structured message].include?(present_as)

          hint = present_as == :text ? " (the `:text` value was renamed to `:message`)" : ""
          raise ArgumentError, "present_as must be one of :structured, :message; got #{present_as.inspect}#{hint}"
        end

        # `guard_tool_response`'s `on_error`: the transport-native error response, plus the operator's
        # only pointer to WHY (the tool-facing text stays generic -- see ADAPTER_FAILURE_MESSAGE).
        # Mirrors axn-openapi's dispatcher hint / axn-mcp's Invocation guard: the config pointer lives
        # HERE rather than in core's exception message, since core raises the same error for adapters
        # with no such setting. Named as BOTH config levels, never just the gem-wide setter -- the
        # value is resolved per-tool, so a `configure(:ruby_llm)` override beats `config`, and core
        # exposes no way to ask which level supplied a resolved value. Non-committal ("if this is")
        # because reject_opaque_exposed_values being on doesn't mean THIS failure is an opaque
        # rejection -- it could equally be a colliding key, a non-finite Float, or a gem bug.
        #
        # The whole hint is built and logged INSIDE a best_effort: `axn_class` is caller code, and
        # interpolating it (a hostile/buggy #to_s) must not raise out of `on_error` -- `guard_tool_response`
        # reports and re-raises an on_error failure rather than substituting a response, so a raise
        # here would cost the tool its error response entirely. Deliberately a SEPARATE best_effort
        # from the guard's own on_exception report: a broken configured logger must not suppress that
        # report, and a broken reporter must not suppress this diagnostic line -- each is the guard's
        # only surviving signal when the OTHER one is what's broken.
        def serialization_failure_response(axn_class, error)
          Axn::Extensions.best_effort("logging a tool serialization failure hint") do
            hint = if Axn::RubyLLM.resolve_override_for(axn_class, :reject_opaque_exposed_values)
                     " (if this is an opaque-value rejection: reject_opaque_exposed_values resolved true for " \
                       "#{axn_class} — unset it on the action via `configure(:ruby_llm)`, or gem-wide via " \
                       "`Axn::RubyLLM.config.reject_opaque_exposed_values = false`, whichever is set)"
                   else
                     ""
                   end
            Axn.config.logger.error { "[axn-ruby_llm] failed to serialize successful result: #{error.class}: #{error.message}#{hint}" }
          end

          { error: ADAPTER_FAILURE_MESSAGE }
        end

        def build_tool_class(axn_class, halt_after:, provider_params:, present_as:, ambient_context:)
          # Core's canonical, provider-safe tool_name (PRO-2921): strips configured leading prefixes,
          # snake_cases with single underscores, restricts to [a-z0-9_], and is never blank (anonymous
          # -> "tool"). Pass the `:ruby_llm` adapter key so a per-adapter `tool ruby_llm: { name: }`
          # override wins -- this is the SAME name `Axn::Tools.for(:ruby_llm)` keys membership,
          # version-collapsing, and sort order on (registry.rb), so `.tools` publishes the exact name
          # the registry selected; the zero-arg form would ignore the override and advertise a
          # different name, so provider tool calls / forced choices on the declared name wouldn't
          # match. Absent an override it's identical to the zero-arg name (Axn::MCP.wrap passes `:mcp`
          # the same way -- the author-once point).
          tool_name = axn_class.tool_name(:ruby_llm)
          input_schema = normalize_nullable_types(annotate_object_constraints(axn_class.input_schema))
          # Built HERE, not inside `define_method(:execute)`: `self` in the executed block is the
          # ::RubyLLM::Tool instance, which has no access to this module's private helpers. Closing
          # over the lambda from build_tool_class's scope binds it to ToolAdapter instead.
          on_serialization_failure = ->(e) { serialization_failure_response(axn_class, e) }

          Class.new(::RubyLLM::Tool) do
            description(axn_class.description) if axn_class.description
            params(input_schema)
            with_params(**provider_params) if provider_params.any?

            define_method(:name) { tool_name }

            define_method(:execute) do |**args|
              # Run the Axn through axn core's tool Invoker (PRO-2943): input types are coerced from the
              # wire, undeclared args are rejected, and a model-supplied `ambient_context` is stripped
              # (the injection guard) while the wrap's own trusted context is injected in its place.
              # Contract violations settle user-facing, so `input_invalid?` lets us hand the model a
              # clean, correctable "Invalid tool arguments" error instead of leaking a dev-facing bug
              # (which also keeps a bad tool call from paging on_exception).
              invoker = ::Axn::Tools::Invoker.new(user_facing_input_errors: true, reject_undeclared_inputs: true)
              result = if ambient_context.equal?(NOT_SET)
                         invoker.call(axn_class, args)
                       else
                         invoker.call(axn_class, args, ambient_context:)
                       end

              unless result.ok?
                next({ error: "Invalid tool arguments: #{result.error}" }) if ::Axn::Tools::Invoker.input_invalid?(result)

                next({ error: result.error })
              end

              # Uphold axn's non-bang "never raises" contract at the adapter boundary. The wrapped
              # Axn's own `.call` (run via the Invoker above) never raises -- core catches action
              # exceptions into a failed Result and pages on_exception itself -- but the TRANSPORT
              # step that runs AFTER it (exposed-value serialization + JSON encoding) can raise
              # outside core's executor: a value core can't render (two Hash keys colliding on one
              # JSON property, a non-finite Float, non-UTF-8 bytes, an opaque value under
              # reject_opaque_exposed_values), a structure past the JSON encoder's max_nesting, or a
              # gem bug. RubyLLM has no rescue around a tool's #execute, so any of these would escape
              # and break the whole chat. `guard_tool_response` (PRO-2996, from
              # Axn::Tools::AdapterSerialization) is core's shared version of exactly that guard --
              # report through the global on_exception inside a best_effort, re-raise when
              # raises_in_dev? so a real bug surfaces loudly, else hand `on_error` the exception so
              # this adapter builds its own transport-native error response. It is scoped to JUST the
              # mapping step (NOT the Invoker call, which already handles + reports its own
              # exceptions -- double-guarding would double-report on_exception), and the block's
              # return value is #execute's.
              Axn::RubyLLM.guard_tool_response(axn_class, on_error: on_serialization_failure) do
                # RubyLLM::Chat#handle_tool_calls only treats a Content/Content::Raw return as-is; any
                # other object (including a plain Hash) gets `#to_s`'d before being sent to the
                # provider -- which for a Hash produces Ruby's inspect syntax (`{"k"=>"v"}`), not
                # JSON. Serialize structured payloads ourselves so the wire form is always valid JSON.
                #
                # `serialize_exposed` (not `Serialization.render` directly) resolves
                # reject_opaque_exposed_values PER CALL off the result's own action class, so a
                # per-tool `configure(:ruby_llm)` override is honored and a config change reaches
                # already-wrapped tools. `present_as` stays a wrap-time kwarg: it's adapter-owned, not
                # part of the shared mixin, and `wrap` accepts it as an explicit override.
                payload = if present_as == :message
                            result.message
                          else
                            Axn::RubyLLM.serialize_exposed(result).to_json
                          end
                halt_after ? halt(payload) : payload
              end
            end
          end
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

        # PRO-3172. RubyLLM's Gemini converter rebuilds every property from a fixed whitelist
        # (`convert_property`: description/enum/format/nullable/maximum/minimum/multipleOf, plus
        # properties/required and, for an array, items/minItems/maxItems). Three keys axn emits for a
        # Hash fall outside it: `additionalProperties` -- a map's value contract, from
        # `of: { keys:, values: }` -- and `minProperties`/`maxProperties`, its entry-count bounds.
        # All three are dropped with no error raised, so a map reaches Gemini as a bare
        # `{type: OBJECT, properties: {}}`: the model never learns what the values must be, sends
        # whatever it likes, and the Invoker rejects the call. The constraint degrades from
        # schema-enforced to runtime-rejected, costing a wasted round trip plus a recovery the model
        # has to work out for itself.
        #
        # Gemini's Schema proto has no equivalent to translate any of them to -- but `description` IS
        # copied through, so restate them as prose there. Applied unconditionally rather than only for
        # Gemini: the adapter has no provider to branch on (a wrapped tool class outlives the choice
        # of chat), and on OpenAI/Anthropic -- which take `params_schema` verbatim and so still get
        # the enforceable keys themselves -- the extra sentence is merely redundant, never wrong.
        #
        # Same non-mutation rule as normalize_nullable_types, for the same reason: axn may hand back
        # a memoized input_schema, so build new Hashes/Arrays throughout.
        def annotate_object_constraints(node)
          case node
          when Hash
            rebuilt = node.to_h { |key, value| [key, annotate_object_constraints(value)] }
            # Read the sentences off the ORIGINAL node, not `rebuilt`: map_sentence may dump the value
            # subschema as JSON, and the original is the copy that has no generated prose in it yet.
            # The JSON clause goes LAST: it ends in a brace rather than a period, so anything appended
            # after it would read as a run-on (and a period placed right after `}` risks being read as
            # part of the JSON itself).
            return rebuilt unless object_node?(node)

            sentences = [map_sentence(node), entry_count_sentence(node), value_schema_clause(node)].compact
            return rebuilt if sentences.empty?

            # merge (rather than assignment into a fresh Hash) so an author-supplied description keeps
            # its original position in the node; the generated sentences follow the author's text.
            rebuilt.merge(description: [node[:description], *sentences].compact.join(" "))
          when Array
            node.map { |value| annotate_object_constraints(value) }
          else
            node
          end
        end

        # A map's value contract as prose. A bare type reads as a plain word -- "integer", "string or
        # integer" -- which says everything the schema does; anything structured is named by its
        # top-level type here and spelled out exactly by value_schema_clause below.
        def map_sentence(node)
          values = map_values(node)
          return nil unless values

          # `additionalProperties` governs only the keys `properties` does NOT match, so a map that
          # also declares a `shape:` carries both on one node -- and Gemini keeps `properties`, which
          # makes "arbitrary keys" actively wrong in that case.
          lead = if node[:properties].is_a?(Hash) && node[:properties].any?
                   "Keys other than those listed map to"
                 else
                   "An object mapping arbitrary keys to"
                 end

          phrase = bare_type_phrase(values)
          phrase ? "#{lead} #{phrase} values." : "#{lead} values."
        end

        # A structured value type -- an array's `items`, a nested map, a constrained scalar -- would
        # need hand-written English grammar to render as prose, which degrades fast with nesting
        # depth, so carry it as compact JSON Schema instead: exact at any depth, and a form models
        # read natively. Skipped when the type word alone already said everything.
        def value_schema_clause(node)
          values = map_values(node)
          return nil if values.nil? || bare_type?(values)

          "Each value must match this JSON Schema: #{JSON.generate(values)}"
        end

        # The recursion above walks every Hash in the schema, but not every Hash IS a schema node --
        # `properties` is a name-to-schema map, so an Axn with a field named `additionalProperties` or
        # `minProperties` puts a Hash (or an Integer) at exactly the key this pass reads. Without this
        # gate, such a container was itself annotated, injecting a `description` key into `properties`
        # and thereby advertising a phantom parameter named "description" -- which the model might then
        # send and the Invoker would reject as undeclared. Requiring a declared object type also keeps
        # object prose off a string/array node that carries these keys for any other reason.
        def object_node?(node)
          type = node[:type]
          type == "object" || (type.is_a?(Array) && type.include?("object"))
        end

        # A map's value schema, or nil if this node isn't a map. axn omits `additionalProperties`
        # entirely rather than emitting an empty one, and never emits the boolean form.
        def map_values(node)
          values = node[:additionalProperties]
          values if values.is_a?(Hash) && values.any?
        end

        # True when a schema constrains nothing beyond the type itself -- exactly the case a type word
        # conveys in full, with no JSON clause needed.
        def bare_type?(schema)
          case schema.keys
          when [:type] then true
          when [:anyOf] then schema[:anyOf].all? { |entry| entry.is_a?(Hash) && entry.keys == [:type] }
          else false
          end
        end

        # "integer"; "integer or null" (axn's array-valued nullable type -- annotation runs BEFORE
        # normalize_nullable_types rewrites it to anyOf); "string or integer" (a union's anyOf). nil
        # when no type is declared at all, which sends the caller to the JSON-only phrasing.
        def bare_type_phrase(schema)
          types = if schema[:type].is_a?(String)
                    [schema[:type]]
                  elsif schema[:type].is_a?(Array)
                    schema[:type]
                  elsif schema[:anyOf].is_a?(Array)
                    schema[:anyOf].filter_map { |entry| entry[:type] if entry.is_a?(Hash) }
                  end

          return nil unless types.is_a?(Array) && types.any? && types.all?(String)

          types.uniq.join(" or ")
        end

        # minProperties/maxProperties. Gemini forwards an ARRAY's minItems/maxItems but has no OBJECT
        # equivalent, so an entry-count bound is lost whether or not the node is also a map -- a plain
        # `expects :meta, type: Hash` already reflects `minProperties: 1` from axn's non-blank default.
        def entry_count_sentence(node)
          min = node[:minProperties]
          max = node[:maxProperties]
          # A zero minimum admits the empty object, i.e. constrains nothing -- reporting it as
          # "must not be empty" below would state the opposite of what the schema allows.
          min = nil unless min.is_a?(Integer) && min.positive?
          max = nil unless max.is_a?(Integer)
          return nil unless min || max

          bound = if min && max && min == max then "exactly #{entry_count(min)}"
                  elsif min && max then "between #{min} and #{entry_count(max)}"
                  elsif max then "at most #{entry_count(max)}"
                  elsif min > 1 then "at least #{entry_count(min)}"
                  end

          # A bare `minProperties: 1` is just non-emptiness, and reads far better said that way.
          bound ? "This object must have #{bound}." : "This object must not be empty."
        end

        def entry_count(count)
          "#{count} #{count == 1 ? "entry" : "entries"}"
        end
      end
    end

    class << self
      def wrap(...)
        ToolAdapter.wrap(...)
      end

      # Every Axn registered as a :ruby_llm tool -- via `tool`/`tool :ruby_llm`, residency under one of
      # the configured `tool_roots`, or a `configure(:ruby_llm)` bag (see Axn::Tools::Registry#member?)
      # -- each already wrapped as a ::RubyLLM::Tool, so a consumer builds its whole chat tool list in
      # one call: `chat.with_tools(*Axn::RubyLLM.tools)`. Mirrors the shared GemName.tools contract
      # with Axn::MCP.tools; the same Axn class resolves to the same tool_name across both surfaces.
      def tools
        Axn::Tools.for(:ruby_llm).map { |axn| wrap(axn) }
      end
    end
  end
end
