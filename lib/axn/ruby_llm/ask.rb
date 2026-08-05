# frozen_string_literal: true

module Axn
  module RubyLLM
    class Ask
      include Axn

      expects :prompt
      expects :json, type: :boolean, default: false
      expects :schema, optional: true
      expects :model, optional: true
      expects :system_prompt, optional: true
      expects :temperature, optional: true
      expects :tools, optional: true

      exposes :response
      exposes :raw_message
      exposes :input_tokens, allow_nil: true
      exposes :output_tokens, allow_nil: true
      exposes :cache_read_tokens, allow_nil: true
      exposes :cache_write_tokens, allow_nil: true
      exposes :prompt_tokens, allow_nil: true
      exposes :cost, allow_nil: true
      exposes :cost_breakdown, allow_nil: true
      exposes :stubbed, type: :boolean, default: false

      StubMessage = Data.define(:content, :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens, :model_id)

      # RubyLLM wraps HTTP-response-level provider errors (4xx/5xx) under RubyLLM::Error, but its
      # non-HTTP errors (bad config, missing model/prompt/role, unsupported attachment) subclass
      # StandardError directly -- so RubyLLM::Error alone misses them. Connection-level failures
      # (timeout, DNS, refused) never reach RubyLLM at all and surface as raw Faraday errors. All
      # three are "known" failure shapes safe to surface verbatim; anything outside this is a bug
      # and must not leak its message into a user-facing result.
      KNOWN_ERROR_CLASSES = [
        ::RubyLLM::Error,
        ::Faraday::Error,
        ::RubyLLM::ConfigurationError,
        ::RubyLLM::ModelNotFoundError,
        ::RubyLLM::PromptNotFoundError,
        ::RubyLLM::InvalidRoleError,
        ::RubyLLM::InvalidToolChoiceError,
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
          input_tokens: sum_across(:input_tokens),
          output_tokens: sum_across(:output_tokens),
          cache_read_tokens: sum_across(:cache_read_tokens),
          cache_write_tokens: sum_across(:cache_write_tokens),
          prompt_tokens: total_input_tokens,
          cost_breakdown:,
          cost: cost_breakdown&.total,
          stubbed: false,
        )
        record_otel_attributes!(
          input_tokens: sum_across(:input_tokens),
          output_tokens: sum_across(:output_tokens),
          cost: cost_breakdown&.total,
          response_model: response_message&.model_id,
          stubbed: false,
        )
      rescue ::RubyLLM::RateLimitError => e
        fail! "Rate limit reached: #{e.message}"
      end

      private

      def disabled? = !Axn::RubyLLM.enabled?

      def stubbed_exposures
        content = schema || json ? { "stubbed" => true } : "stubbed response value"
        {
          response: content,
          raw_message: StubMessage.new(content:, input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, model_id: "stubbed"),
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
        if schema
          # with_schema makes RubyLLM parse the response into a Hash on success
          return llm_response.content if llm_response.content.is_a?(Hash)

          fail! "Schema response was not valid JSON"
        end
        json ? JSON.parse(llm_response.content) : llm_response.content
      end

      # A tool call makes multiple model round-trips inside one `ask`; every assistant turn is
      # accumulated on the chat and reports its OWN usage, so sum across them for the true per-call
      # totals rather than just the final turn's. Non-response messages (the user prompt, tool
      # results) carry no tokens — they contribute 0 to the token sums, and RubyLLM::Cost.aggregate
      # ignores them (no `tokens?`) — so summing over every message is correct, and a plain (no-tool)
      # ask (one assistant turn) is a no-op.
      def usage_messages
        chat.messages
      end

      # nil only when NO turn reported the field (preserving the "nil if the provider didn't return it"
      # contract); otherwise the summed count, treating a missing turn as 0.
      def sum_across(field)
        values = usage_messages.map(&field)
        values.all?(&:nil?) ? nil : values.sum(&:to_i)
      end

      def total_input_tokens
        vals = usage_messages.flat_map { |m| [m.input_tokens, m.cache_read_tokens, m.cache_write_tokens] }
        vals.all?(&:nil?) ? nil : vals.sum(&:to_i)
      end

      memo def cost_breakdown
        return nil unless model_info

        costs = usage_messages.map { |message| message.cost(model: model_info) }
        return nil if costs.empty?

        # One turn → its own Cost (identical to a non-tool call). Multiple → RubyLLM::Cost.aggregate
        # sums the per-tier costs into a single breakdown.
        costs.one? ? costs.first : ::RubyLLM::Cost.aggregate(costs)
      end

      memo def model_info
        return nil unless response_message&.model_id

        ::RubyLLM.models.find(response_message.model_id)
      rescue ::RubyLLM::ModelNotFoundError
        nil
      end

      memo def llm_response = chat.ask(prompt)

      # When a wrapped tool halts the loop (halt_after:), chat.ask returns a ::RubyLLM::Tool::Halt
      # carrying the tool payload as #content, not a Message — and a Halt has no #model_id. Read the
      # model (for cost lookup + OTel) from the last assistant turn accumulated on the chat in that
      # case; for a normal response, llm_response IS that final message. Token/cost SUMS already read
      # chat.messages, so only the model-id reads needed this indirection.
      def response_message
        return llm_response unless llm_response.is_a?(::RubyLLM::Tool::Halt)

        chat.messages.reverse.find { |message| message.role == :assistant }
      end

      memo def chat
        ::RubyLLM.chat(model: resolved_model).tap do |c|
          c.with_instructions(system_prompt) if system_prompt
          c.with_schema(schema) if schema
          c.with_params(response_format: { type: "json_object" }) if json && !schema
          c.with_params(temperature:) if temperature
          c.with_tools(*resolved_tools) if resolved_tools.any?
        end
      end

      def resolved_model
        model || Axn::RubyLLM.config.default_model
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
        # Telemetry is a best-effort side effect: it must never break the LLM call. Route it through
        # axn core's guard (PRO-2950) rather than a bare rescue — it swallows + warn-logs on failure
        # (and fails loud in dev when best_effort_raises_in_dev is set) instead of silently vanishing.
        Axn::Extensions.best_effort("recording OpenTelemetry attributes on the axn.call span") do
          next unless defined?(::OpenTelemetry::Trace)

          span = ::OpenTelemetry::Trace.current_span
          next unless span&.context&.valid?

          span.set_attribute("gen_ai.request.model", resolved_model) if resolved_model
          span.set_attribute("gen_ai.response.model", response_model) if response_model
          span.set_attribute("gen_ai.usage.input_tokens", input_tokens) if input_tokens
          span.set_attribute("gen_ai.usage.output_tokens", output_tokens) if output_tokens
          span.set_attribute("gen_ai.usage.cost", cost) if cost
          span.set_attribute("axn.ruby_llm.stubbed", stubbed) unless stubbed.nil?
        end
      end
    end
  end
end
