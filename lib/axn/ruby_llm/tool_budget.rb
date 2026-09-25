# frozen_string_literal: true

module Axn
  module RubyLLM
    # A shared cap on how many tool calls one chat may make. Backs both `remote_mcp_tools(max_calls:)`
    # (one budget per toolset) and `Ask`'s `max_tool_calls:` (one budget per `ask`, across every
    # app-executed tool). RubyLLM 2.0 removed `Tool::Halt` / `halt_after:`, so `Chat#complete` has no
    # iteration cap of its own.
    #
    # Soft by design: an exhausted budget answers each further call with an error result telling the
    # model to wrap up, rather than raising -- running out is a normal end state for a long research
    # loop, and raising would throw away everything the chat gathered so far. The Mutex keeps the
    # count exact under `tool_options: { concurrency: :threads }`.
    class ToolBudget
      attr_reader :max_calls

      def initialize(max_calls, noun: "tool calls")
        @max_calls = max_calls
        @noun = noun
        @count = 0
        @mutex = Mutex.new
      end

      # Returns true (and reserves a slot) when a call is still allowed, false once max_calls has
      # been reached.
      def consume!
        @mutex.synchronize do
          return false if @count >= @max_calls

          @count += 1
          true
        end
      end

      def exhausted_result
        { error: "Tool call budget exhausted (#{@max_calls} #{@noun} allowed) -- " \
                 "write your final answer with what you have so far." }
      end

      # Returns a tool instance whose every call draws from this budget. A class is instantiated; an
      # instance is dup'd first, so the caller's own instance (e.g. one from
      # `Axn::RubyLLM.wrap(axn, ambient_context:)`, possibly reused across asks) is never mutated.
      # RubyLLM's Chat#with_tools registers an instance as-is, and runs it via Tool#call.
      def guard(tool)
        budget = self
        instance = tool.is_a?(::Class) ? tool.new : tool.dup
        instance.extend(Module.new do
          define_method(:call) do |tool_call: nil, **arguments|
            next budget.exhausted_result unless budget.consume!

            super(tool_call:, **arguments)
          end
        end)
      end
    end
  end
end
