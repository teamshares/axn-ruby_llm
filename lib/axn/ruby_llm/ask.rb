# frozen_string_literal: true

module Axn
  module RubyLLM
    class Ask
      include Axn

      expects :prompt
      expects :schema, optional: true
      expects :model, optional: true
      expects :system_prompt, optional: true
      expects :temperature, optional: true
      expects :tools, optional: true
      # Forwarded verbatim to Chat#with_provider_tools -- a Hash of alias => options, e.g.
      # `provider_tools: { mcp: { name:, url:, headers:, allowed_tools:, require_approval: } }` for a
      # provider-hosted remote MCP server, or `{ web_search: {} }`. See RubyLLM::Chat#with_provider_tools.
      expects :provider_tools, optional: true
      # Forwarded verbatim to Chat#with_tool_options (choice:/calls:/concurrency:).
      expects :tool_options, optional: true
      # A callable given each pending ToolCall (from Chat#pending_approvals -- local tools declared
      # with `requires_approval`, or provider-hosted remote calls awaiting an mcp_approval_request) and
      # returning truthy to approve, falsy to deny. Required to drive a chat past #awaiting_approval? --
      # without it, `llm_response` is whatever #ask returned when the loop first parked, and the
      # response schema/tool loop never completes. Only meaningful alongside provider_tools using
      # require_approval, or a local tool declared with `requires_approval`.
      expects :on_remote_tool_approval, optional: true

      exposes :response
      exposes :raw_message
      # A plain-Hash summary of every message the chat exchanged (system prompt excluded), in order:
      # role, content, tool_calls (name/arguments/remote?), tool_call_id, and server_tool_calls (the
      # provider-executed calls a hosted MCP server ran, e.g. Metabase queries). Built once per call
      # from Chat#messages, which RubyLLM already retains -- this only shapes it for a caller that
      # doesn't want to reach into raw RubyLLM::Message objects.
      exposes :transcript, type: Array, allow_blank: true
      exposes :input_tokens, allow_nil: true
      exposes :output_tokens, allow_nil: true
      exposes :cache_read_tokens, allow_nil: true
      exposes :cache_write_tokens, allow_nil: true
      exposes :prompt_tokens, allow_nil: true
      exposes :cost, allow_nil: true
      exposes :cost_breakdown, allow_nil: true
      exposes :stubbed, type: :boolean, default: false

      # Shape-compatible with a real ::RubyLLM::Message on the disabled path: `.content` is the raw
      # text (JSON when `schema:` is set, matching 2.0's read-only String #content), `.tokens` is a
      # real ::RubyLLM::Tokens (so `.input`/`.output`/`.cache_read`/`.cache_write` all resolve), and
      # `.parsed` mirrors Message#parsed (memoized JSON.parse over #content).
      StubMessage = Data.define(:content, :tokens, :model) do
        def parsed
          return if content.nil? || content.empty?

          JSON.parse(content)
        end
      end

      # RubyLLM wraps HTTP-response-level provider errors (4xx/5xx) under RubyLLM::Error, but its
      # non-HTTP errors (bad config, missing model/prompt/role, unsupported attachment, a stale model
      # registry, an unresolved pending-tool-call/approval loop state) subclass StandardError
      # directly -- so RubyLLM::Error alone misses them. Connection-level failures (timeout, DNS,
      # refused) never reach RubyLLM at all and surface as raw Faraday errors. All these are "known"
      # failure shapes safe to surface verbatim; anything outside this is a bug and must not leak its
      # message into a user-facing result.
      KNOWN_ERROR_CLASSES = [
        ::RubyLLM::Error,
        ::Faraday::Error,
        ::RubyLLM::ConfigurationError,
        ::RubyLLM::ModelNotFoundError,
        ::RubyLLM::ModelRegistryError,
        ::RubyLLM::PromptNotFoundError,
        ::RubyLLM::InvalidRoleError,
        ::RubyLLM::InvalidToolChoiceError,
        ::RubyLLM::PendingToolCallsError,
        ::RubyLLM::CancelledError,
        ::RubyLLM::UnsupportedAttachmentError,
      ].freeze
      KNOWN_ERROR = ->(exception:) { KNOWN_ERROR_CLASSES.any? { |k| exception.is_a?(k) } }
      RETRYABLE_ERROR = lambda { |exception:|
        [::RubyLLM::OverloadedError, ::RubyLLM::ServiceUnavailableError, ::RubyLLM::ServerError].any? { |k| exception.is_a?(k) }
      }

      # Base headlines for a consistent result.error / result.success surface: failures read
      # "<error_headline>: <reason>" (configurable via Axn::RubyLLM.configure); successes read
      # "LLM request completed", with any detail attached parenthetically via join: (e.g. the
      # stubbed-values note on the disabled path below).
      # Reason entries are ordered most-specific-last (axn checks most-recently-declared first), so a
      # narrower match (retryable, context length, JSON parse) wins over the generic KNOWN_ERROR catch-all.
      error { Axn::RubyLLM.config.error_headline }
      error(if: KNOWN_ERROR, &:message)
      error(if: RETRYABLE_ERROR) { |e| "Provider temporarily unavailable, try again later: #{e.message}" }
      error(if: ::RubyLLM::ContextLengthExceededError) { |e| "Prompt exceeds the model's context window: #{e.message}" }
      error "Response was not valid JSON", if: JSON::ParserError
      success "LLM request completed", join: ->(base, reason) { "#{base} (#{reason})" }

      before do
        if disabled?
          exposures = stubbed_exposures
          record_otel_attributes!(
            input_tokens: exposures[:input_tokens],
            output_tokens: exposures[:output_tokens],
            cost: exposures[:cost],
            response_model: nil,
            stubbed: true,
          )
          # Reason attaches to the "LLM request completed" base via the parenthetical join: above.
          done!("using stubbed values - actual LLM request disabled", **exposures)
        end
      end

      def call
        expose(
          response: parsed_response,
          raw_message: llm_response,
          transcript: transcript_entries,
          input_tokens: token_usage.input,
          output_tokens: token_usage.output,
          cache_read_tokens: token_usage.cache_read,
          cache_write_tokens: token_usage.cache_write,
          prompt_tokens: total_input_tokens,
          cost_breakdown:,
          cost: cost_breakdown&.total,
          stubbed: false,
        )
        record_otel_attributes!(
          input_tokens: token_usage.input,
          output_tokens: token_usage.output,
          cost: cost_breakdown&.total,
          response_model: llm_response&.model,
          stubbed: false,
        )
      rescue ::RubyLLM::RateLimitError => e
        fail! "Rate limit reached: #{e.message}"
      end

      private

      def disabled? = !Axn::RubyLLM.enabled?

      def stubbed_exposures
        parsed_content = schema ? { "stubbed" => true } : nil
        content = parsed_content ? parsed_content.to_json : "stubbed response value"
        zero_tokens = ::RubyLLM::Tokens.new(input: 0, output: 0, cache_read: 0, cache_write: 0)
        {
          response: parsed_content || content,
          raw_message: StubMessage.new(content:, tokens: zero_tokens, model: "stubbed"),
          transcript: [],
          input_tokens: 0,
          output_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          prompt_tokens: 0,
          cost: 0.0,
          cost_breakdown: nil,
          stubbed: true,
        }
      end

      def parsed_response
        return llm_response.content unless schema

        # with_schema makes RubyLLM parse the response into JSON text on success; #parsed memoizes
        # JSON.parse over #content and raises JSON::ParserError on malformed JSON (caught by the
        # declared `error "Response was not valid JSON", if: JSON::ParserError` handler above).
        parsed = llm_response.parsed
        return parsed if parsed.is_a?(Hash)

        fail! "Schema response was not valid JSON"
      end

      # Every provider attempt this chat has made -- including retries and fallback attempts that
      # produced no message -- aggregated by RubyLLM itself (Chat#tokens / Chat#cost), rather than
      # summed by hand across chat.messages. A tool call makes multiple model round-trips inside one
      # `ask`; this still reflects the whole call, not just the final response.
      memo def token_usage = chat.tokens
      memo def cost_breakdown = chat.cost

      # nil only when NO turn reported the field (preserving the "nil if the provider didn't return
      # it" contract); otherwise the summed count, treating a missing component as 0.
      def total_input_tokens
        vals = [token_usage.input, token_usage.cache_read, token_usage.cache_write]
        vals.all?(&:nil?) ? nil : vals.sum(&:to_i)
      end

      # Without on_remote_tool_approval, this is exactly #ask -- one #complete run, parked (like
      # before this feature existed) if the chat lands on an unresolved approval. With it, drive
      # #complete past every approval Chat#pending_approvals reports, until the loop truly finishes.
      # Chat#complete already loops through ordinary tool calls on its own; this only extends that
      # loop across the approval pauses it otherwise stops at.
      memo def llm_response
        message = chat.ask(prompt)
        return message unless on_remote_tool_approval

        while chat.awaiting_approval?
          chat.pending_approvals.each do |tool_call|
            on_remote_tool_approval.call(tool_call) ? chat.approve(tool_call) : chat.deny(tool_call)
          end
          message = chat.complete
        end
        message
      end

      memo def chat
        ::RubyLLM.chat(model: resolved_model).tap do |c|
          c.with_instructions(system_prompt) if system_prompt
          c.with_schema(resolved_schema) if schema
          c.with_temperature(temperature) if temperature
          c.with_tools(*resolved_tools) if resolved_tools.any?
          c.with_provider_tools(**provider_tools) if provider_tools
          c.with_tool_options(**tool_options) if tool_options
        end
      end

      # chat.messages already retains the whole exchange (RubyLLM's own Chat#tokens / Chat#cost read
      # off it the same way) -- this only reshapes each Message into a plain Hash a caller can log or
      # assert against without reaching into RubyLLM::Message/ToolCall objects. The system prompt is
      # excluded: it's an Ask input the caller already has (system_prompt), not something the loop
      # produced.
      def transcript_entries
        chat.messages.reject { |m| m.role == :system }.map do |m|
          {
            role: m.role,
            content: m.content.is_a?(String) ? m.content : nil,
            tool_calls: m.tool_calls&.transform_values { |tc| { name: tc.name, arguments: tc.arguments, remote: tc.remote? } },
            tool_call_id: m.tool_call_id,
            server_tool_calls: m.server_tool_calls,
          }
        end
      end

      def resolved_model
        model || Axn::RubyLLM.config.default_model
      end

      # `schema:` accepts a raw JSON Schema Hash (passed through unchanged -- Chat#with_schema
      # already normalizes a bare Hash), a Schematist::Schema class/instance (likewise passed
      # through -- with_schema itself checks for #to_json_schema), or an Axn class: the same
      # reflection the tool adapter already uses for input (`input_schema`), mirrored here for
      # output. `output_schema` is axn's own public JSON Schema Hash for its `exposes` contract.
      #
      # Adjustments axn's own `exposes` contract has no reason to make on its own -- each one
      # confirmed live against a real model, not just read off docs (a docs summary claimed
      # `minLength` was ALSO unsupported by Anthropic; a flat schema with `minLength: 1` on a
      # String field succeeded live regardless, so only what's actually confirmed failing is
      # stripped, nothing broader):
      #
      # - `additionalProperties: false` on every fixed-shape object node. Anthropic's
      #   `output_config.format.schema` REQUIRES this unconditionally -- confirmed live
      #   ("output_config.format.schema: For 'object' type, 'additionalProperties' must be
      #   explicitly set to false"), and it deletes any `strict:` key before validating
      #   (protocols/anthropic/chat.rb#build_output_config), so there is no "non-strict" escape
      #   hatch there. OpenAI's strict mode has the same requirement (its own docs / community
      #   reports). Injected on every object node that declares `properties` and has no
      #   `additionalProperties` of its own -- which excludes a map (`type: Hash, of: {...}`),
      #   whose `additionalProperties` already names its value schema and must stay that way.
      # - `minProperties`/`maxProperties` stripped from every object node. axn emits
      #   `minProperties: 1` on any fixed-shape object (a nested `type: Hash, shape: {...}` field,
      #   or a map) by default -- Anthropic's schema validator rejects it outright, confirmed live
      #   ("output_config.format.schema: For 'object' type, property 'minProperties' is not
      #   supported"). No prose-restatement fallback (the kind PRO-3172's now-deleted Gemini
      #   workaround used) -- that machinery existed for a fixed-whitelist converter Gemini no
      #   longer has (see tool_adapter.rb); reintroducing it here for a narrower, less common case
      #   (a nested fixed-shape object's entry-count bound) isn't worth the complexity back.
      # - `strict: false`, pinned rather than left to RubyLLM's own inference. Chat#with_schema's
      #   strict_schema? (chat_completions/chat.rb) infers `strict: true` whenever every property
      #   is required -- the common case for an Axn's output contract (see the README example) --
      #   and OpenAI's *full* strict mode additionally requires every property to be listed in
      #   `required` even when conceptually optional (via a nullable type), which axn's reflection
      #   doesn't promise. Pinned rather than relying on the `additionalProperties: false` fix
      #   above to make strict inference merely harmless.
      def resolved_schema
        return schema unless schema.is_a?(::Class) && schema.respond_to?(:output_schema)

        { name: schema.name || "response", schema: sanitize_output_schema(schema.output_schema), strict: false }
      end

      # Builds a new Hash/Array throughout rather than mutating -- axn may hand back a memoized
      # output_schema, and mutating it would corrupt every other reader.
      #
      # Every adjustment is gated on `object_node` -- the recursion walks every Hash in the
      # schema, but not every Hash IS a schema node. `properties` is a name-to-schema map, so an
      # Axn with a field literally named `minProperties`/`maxProperties`/`additionalProperties`
      # puts a Hash at exactly the key this pass reads; an ungated delete/injection would corrupt
      # that container instead of a schema node's own keywords (confirmed live: an Axn exposing
      # `minProperties` had that field silently dropped from `properties` while `required` still
      # named it -- an invalid schema). The `properties` container itself never carries `type`, so
      # gating on `object_node` -- true only for an actual object-schema node -- keeps the pass off
      # it entirely.
      def sanitize_output_schema(node)
        case node
        when Hash
          rebuilt = node.transform_values { |value| sanitize_output_schema(value) }
          object_node = rebuilt[:type] == "object" || Array(rebuilt[:type]).include?("object")
          if object_node
            rebuilt.delete(:minProperties)
            rebuilt.delete(:maxProperties)
            rebuilt[:additionalProperties] = false if rebuilt.key?(:properties) && !rebuilt.key?(:additionalProperties)
          end
          rebuilt
        when Array
          node.map { |value| sanitize_output_schema(value) }
        else
          node
        end
      end

      # `tools:` accepts a mix of bare Axn classes (wrapped here, so callers can pass their own Axns
      # straight in) and already-wrapped `::RubyLLM::Tool`s -- a class or an instance, the latter being
      # how you pass a tool that closed over explicit context via `Axn::RubyLLM.wrap(axn, ambient_context:)`.
      # RubyLLM's `with_tools` accepts either a class or an instance, so wrapped classes register as-is.
      def resolved_tools
        Array(tools).map { |tool| _as_ruby_llm_tool(tool) }
      end

      def _as_ruby_llm_tool(tool)
        return tool if tool.is_a?(::RubyLLM::Tool)
        return tool if tool.is_a?(::Class) && tool < ::RubyLLM::Tool

        Axn::RubyLLM.wrap(tool)
      end

      def record_otel_attributes!(input_tokens:, output_tokens:, cost:, response_model:, stubbed:)
        Axn::Extensions::Tracing.annotate_span(
          "gen_ai.request.model" => resolved_model,
          "gen_ai.response.model" => response_model,
          "gen_ai.usage.input_tokens" => input_tokens,
          "gen_ai.usage.output_tokens" => output_tokens,
          "gen_ai.usage.cost" => cost,
          "axn.ruby_llm.stubbed" => stubbed,
        )
      end
    end
  end
end
