# frozen_string_literal: true

module Axn
  module RubyLLM
    # Namespaced per-class config (axn's `Axn::Configurable`, PRO-2880): any Axn — with no
    # adapter-specific mixin required — can declare `configure(:ruby_llm) { |c| c.present_as = :message }`
    # to set these per-class, alongside e.g. `configure(:mcp) { ... }` for a different adapter on the
    # same class, without the two colliding. `wrap` resolves them via `resolve_override_for`, which
    # falls back to this module's own global `config` (`Axn::RubyLLM.configure { |c| ... }`) and then
    # to each setting's default — the same class-override-then-global-then-default chain a flat
    # `overridable: true` accessor would give a single-adapter consumer.
    config_namespace :ruby_llm
    setting :provider_options, default: {}, overridable: true
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
        def wrap(axn_class, provider_options: nil, present_as: nil, render_as: NOT_SET, provider_params: NOT_SET, ambient_context: NOT_SET)
          validate_present_as_kwargs!(present_as, render_as)
          validate_provider_options_kwargs!(provider_params)

          tool_class = build_tool_class(
            axn_class,
            provider_options: provider_options.nil? ? Axn::RubyLLM.resolve_override_for(axn_class, :provider_options) : provider_options,
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

        # `provider_params:` was renamed to `provider_options:` (PRO-3467) to match RubyLLM 2.0's own
        # `Tool.provider_options`, which replaced `with_params` for tool-level provider metadata.
        # Same hard-error treatment as `render_as:` above: pre-1.0, never silently shimmed.
        def validate_provider_options_kwargs!(provider_params)
          return if provider_params.equal?(NOT_SET)

          raise ArgumentError,
                "`provider_params:` was renamed to `provider_options:` " \
                "(e.g. `Axn::RubyLLM.wrap(..., provider_options: { ... })`)."
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

        def build_tool_class(axn_class, provider_options:, present_as:, ambient_context:)
          # Core's canonical, provider-safe tool_name (PRO-2921): strips configured leading prefixes,
          # snake_cases with single underscores, restricts to [a-z0-9_], and is never blank (anonymous
          # -> "tool"). Pass the `:ruby_llm` adapter key so a per-adapter `tool ruby_llm: { name: }`
          # override wins -- this is the SAME name `Axn::Tools.for(:ruby_llm)` keys membership,
          # version-collapsing, and sort order on (registry.rb), so `.tools` publishes the exact name
          # the registry selected; the zero-arg form would ignore the override and advertise a
          # different name, so provider tool calls / forced choices on the declared name wouldn't
          # match. Absent an override it's identical to the zero-arg name (Axn::MCP.wrap passes `:mcp`
          # the same way -- the author-once point).
          #
          # Passed through unmodified (PRO-3467): RubyLLM 2.0's Gemini protocol reads a tool's schema
          # via `parametersJsonSchema` -- the wire form verbatim, with no whitelist converter in the
          # way -- so the array-valued-`type` / additionalProperties / min-maxProperties workarounds
          # 1.x needed here are gone along with the fixed-property Gemini schema converter they patched
          # around.
          tool_name = axn_class.tool_name(:ruby_llm)
          input_schema = axn_class.input_schema
          # Built HERE, not inside `define_method(:execute)`: `self` in the executed block is the
          # ::RubyLLM::Tool instance, which has no access to this module's private helpers. Closing
          # over the lambda from build_tool_class's scope binds it to ToolAdapter instead.
          on_serialization_failure = ->(e) { serialization_failure_response(axn_class, e) }

          Class.new(::RubyLLM::Tool) do
            description(axn_class.description) if axn_class.description
            parameters(input_schema)
            provider_options(provider_options) if provider_options.any?

            define_singleton_method(:tool_name) { tool_name }

            define_method(:execute) do |**args|
              # Run the Axn through axn core's tool Invoker (PRO-2943): input types are coerced from the
              # wire, undeclared args are rejected, and a model-supplied `ambient_context` is stripped
              # (the injection guard) while the wrap's own trusted context is injected in its place.
              # Contract violations settle user-facing, so `input_invalid?` lets us hand the model a
              # clean, correctable "Invalid tool arguments" error instead of leaking a dev-facing bug
              # (which also keeps a bad tool call from paging on_exception). `adapter: :ruby_llm`
              # (PRO-3332) stamps the invoked_via dimension around the call, so a Datadog dashboard can
              # separate tool-driven traffic from ordinary direct `.call`s with no per-call work here.
              invoker = ::Axn::Tools::Invoker.new(adapter: :ruby_llm, user_facing_input_errors: true, reject_undeclared_inputs: true)
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
                # RubyLLM::Tool.split_result (called from Chat#add_tool_result_message) sends a String
                # through as-is but `#to_json`'s a returned Hash/Array only via its OWN #to_json
                # dispatch, not necessarily matching how axn would serialize it (Symbol keys/values,
                # BigDecimal, Time, opaque-value rejection). Serialize structured payloads ourselves so
                # the wire form always reflects axn's own serialization contract, not Ruby's default.
                #
                # `serialize_exposed` (not `Serialization.render` directly) resolves
                # reject_opaque_exposed_values PER CALL off the result's own action class, so a
                # per-tool `configure(:ruby_llm)` override is honored and a config change reaches
                # already-wrapped tools. `present_as` stays a wrap-time kwarg: it's adapter-owned, not
                # part of the shared mixin, and `wrap` accepts it as an explicit override.
                if present_as == :message
                  result.message
                else
                  Axn::RubyLLM.serialize_exposed(result).to_json
                end
              end
            end
          end
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
