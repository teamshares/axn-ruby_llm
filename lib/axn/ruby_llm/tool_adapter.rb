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
    setting :reject_opaque_exposed_values, default: false, one_of: [true, false], overridable: true

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
            reject_opaque: Axn::RubyLLM.resolve_override_for(axn_class, :reject_opaque_exposed_values),
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

        def build_tool_class(axn_class, halt_after:, provider_params:, present_as:, reject_opaque:, ambient_context:)
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
          input_schema = normalize_nullable_types(axn_class.input_schema)

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
              # reject_opaque), a structure past the JSON encoder's max_nesting, or a gem bug.
              # RubyLLM has no rescue around a tool's #execute, so any of these would escape and
              # break the whole chat. Scope the guard to JUST that mapping step (NOT the Invoker call,
              # which already handles + reports its own exceptions -- double-guarding would
              # double-report on_exception): report through axn's global on_exception for
              # observability, then -- honoring core's best_effort_raises_in_dev so a real bug
              # surfaces loudly rather than being masked -- re-raise in dev, otherwise return a tool
              # error so #execute ALWAYS yields a value. Shaped to drop into the planned shared
              # Axn::Tools::Serialization.guard (PRO-2996 §2b) with no behavior change.
              begin
                # RubyLLM::Chat#handle_tool_calls only treats a Content/Content::Raw return as-is; any
                # other object (including a plain Hash) gets `#to_s`'d before being sent to the
                # provider -- which for a Hash produces Ruby's inspect syntax (`{"k"=>"v"}`), not
                # JSON. Serialize structured payloads ourselves so the wire form is always valid JSON.
                payload = if present_as == :message
                            result.message
                          else
                            Axn::Extensions::Serialization.render(result, reject_opaque:).to_json
                          end
                halt_after ? halt(payload) : payload
              rescue StandardError => e
                # Report through on_exception for observability -- but the reporter is app-configured
                # and CAN raise (a buggy hook, or one assuming `action` is a settled instance). Core
                # normally invokes on_exception INSIDE its own best_effort; we call it directly, so a
                # raising reporter would escape and defeat this guard's never-raises intent (aborting
                # chat.ask in production). Wrap it in best_effort ourselves -- it swallows + warn-logs
                # (and reraises in dev per best_effort_raises_in_dev), same as core.
                Axn::Extensions.best_effort("reporting a tool serialization failure via on_exception") do
                  Axn.config.on_exception(e, action: axn_class, context: { source: "Axn::RubyLLM" })
                end

                # The tool-facing error stays generic (ADAPTER_FAILURE_MESSAGE) -- this line is an
                # operator's only pointer to WHY. Mirrors axn-openapi's dispatcher hint / axn-mcp's
                # Invocation guard: the config pointer lives HERE rather than in core's exception
                # message, since core raises the same error for adapters with no such setting. Named
                # as BOTH config levels, never just the gem-wide setter -- the value is resolved
                # per-tool, so a `configure(:ruby_llm)` override beats `config`, and core exposes no
                # way to ask which level supplied a resolved value. Non-committal ("if this is")
                # because reject_opaque being on doesn't mean THIS failure is an opaque rejection --
                # it could equally be a colliding key, a non-finite Float, or a gem bug.
                # `resolved_axn_name` (axn core), not raw `#{axn_class}`: Class#to_s does NOT dispatch
                # through an overridden `.name` (it renders the object-id form regardless), so a class
                # with no assigned constant -- e.g. one built via Axn::Factory.build -- would otherwise
                # show as `#<Class:0x...>` instead of naming the action. Built INSIDE the best_effort
                # block, not before it: axn_class is caller code, so a hostile/buggy `resolved_axn_name`
                # override must not raise outside the guard meant to contain exactly that. A separate
                # best_effort from the on_exception report above, deliberately: a broken configured
                # logger must not suppress the on_exception report (which already ran), and a broken
                # on_exception reporter must not suppress this diagnostic line either -- each is the
                # guard's only surviving signal when the OTHER one is what's broken.
                Axn::Extensions.best_effort("logging a tool serialization failure hint") do
                  hint = if reject_opaque
                           " (if this is an opaque-value rejection: reject_opaque_exposed_values resolved true for " \
                             "#{axn_class.resolved_axn_name} — unset it on the action via `configure(:ruby_llm)`, " \
                             "or gem-wide via `Axn::RubyLLM.config.reject_opaque_exposed_values = false`, whichever is set)"
                         else
                           ""
                         end
                  Axn.config.logger.error { "[axn-ruby_llm] failed to serialize successful result: #{e.class}: #{e.message}#{hint}" }
                end

                raise if Axn::Extensions.raises_in_dev?

                { error: ADAPTER_FAILURE_MESSAGE }
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
