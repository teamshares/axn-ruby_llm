# frozen_string_literal: true

require "mcp"

module Axn
  module RubyLLM
    # Wraps a remote MCP server's tools as ordinary ::RubyLLM::Tool subclasses, so they can sit
    # next to Axn-wrapped local tools in the same `tools:` array (Ask, or `chat.with_tools`).
    #
    # This is the APP-SIDE alternative to `Chat#with_provider_tools(mcp: {...})`: with that, the
    # *provider* connects to the server directly and its tool calls happen inside the provider's own
    # request, invisible to this app. Here, THIS process connects, so every call is one this app makes,
    # logs, times out, and can cap -- at the cost of an extra round-trip per remote tool call (the
    # provider calls back into this app's chat loop, rather than looping against the MCP server itself).
    module RemoteMcp
      DEFAULT_MAX_CALLS = 20
      DEFAULT_TIMEOUT = 60
      DEFAULT_MAX_RESULT_CHARS = 20_000

      # The budget is shared across every tool the toolset wraps -- one counter per `connect`, not
      # per tool -- because the limit exists to bound how many round-trips ONE chat makes to the
      # remote server in total, not how many times any single tool gets called. A Mutex (not
      # Concurrent::AtomicFixnum) is enough for the sequential tool-call path this ships with; see
      # the axn-ruby_llm pass-through ticket for a lock-free version once concurrent remote calls land.
      class Budget
        attr_reader :max_calls

        def initialize(max_calls)
          @max_calls = max_calls
          @count = 0
          @mutex = Mutex.new
        end

        # Returns true (and reserves a slot) when a call is still allowed, false once max_calls has
        # been reached. Never raises -- an exhausted budget is a normal, expected end state for a
        # long research loop, not a bug.
        def consume!
          @mutex.synchronize do
            return false if @count >= @max_calls

            @count += 1
            true
          end
        end
      end

      # Holds the connected client alongside the wrapped tools so the caller can `close` it when
      # done (an MCP::Client::HTTP session is a real HTTP connection, possibly with a live SSE
      # listener thread -- see MCP::Client::HTTP#close). `tools` is what actually gets passed to
      # `chat.with_tools` / `Axn::RubyLLM.ask(tools:)`.
      Toolset = Struct.new(:tools, :client, keyword_init: true) do
        # MCP::Client itself has no #close -- only its transport does (a real HTTP connection,
        # possibly with a live SSE listener thread).
        def close
          client.transport.close
        end
      end

      class << self
        # Connects to a remote MCP server over Streamable HTTP and returns a Toolset: one
        # ::RubyLLM::Tool subclass per allowed remote tool, plus the underlying client for `close`.
        #
        #   toolset = Axn::RubyLLM.remote_mcp_tools(
        #     url: ENV.fetch("METABASE_MCP_URL"),
        #     headers: { "X-API-KEY" => ENV.fetch("METABASE_MCP_API_KEY") },
        #     allowed_tools: %w[search read_resource execute_sql],
        #   )
        #   Axn::RubyLLM.ask(prompt: "...", tools: [*Axn::RubyLLM.tools, *toolset.tools])
        #   toolset.close
        #
        # allowed_tools is not a convenience -- pass it. A server's full tool list can include
        # write/admin tools (e.g. Metabase's create_dashboard, update_question) that have no
        # business being reachable from an LLM's own tool choices; nil (the default) keeps
        # everything the server advertises, so an omitted allowlist is a deliberate "trust every
        # tool this server exposes," not a safe default.
        def remote_mcp_tools(url:, headers: {}, allowed_tools: nil, max_calls: DEFAULT_MAX_CALLS,
                             timeout: DEFAULT_TIMEOUT, max_result_chars: DEFAULT_MAX_RESULT_CHARS)
          client = connect_client(url:, headers:, timeout:)
          remote_tools = client.tools
          remote_tools = remote_tools.select { |t| allowed_tools.include?(t.name) } if allowed_tools

          budget = Budget.new(max_calls)
          wrapped = remote_tools.map { |remote_tool| build_tool_class(remote_tool, client:, budget:, max_result_chars:) }

          Toolset.new(tools: wrapped, client:)
        end

        private

        def connect_client(url:, headers:, timeout:)
          transport = ::MCP::Client::HTTP.new(url:, headers:) do |faraday|
            faraday.options.timeout = timeout
            faraday.options.open_timeout = timeout
          end
          ::MCP::Client.new(transport:).tap(&:connect)
        end

        def build_tool_class(remote_tool, client:, budget:, max_result_chars:)
          tool_name = remote_tool.name
          tool_description = remote_tool.description
          input_schema = remote_tool.input_schema || { type: "object", properties: {} }

          Class.new(::RubyLLM::Tool) do
            description(tool_description) if tool_description
            parameters(input_schema)

            define_singleton_method(:tool_name) { tool_name }

            define_method(:execute) do |**args|
              Axn::RubyLLM::RemoteMcp.send(:call_remote_tool, client:, tool_name:, args:, budget:, max_result_chars:)
            end
          end
        end

        # Isolated from build_tool_class's closure (rather than inlined in the define_method block)
        # so the rescue clauses -- the part most likely to need a new case as real servers are
        # exercised -- are easy to find and extend on their own, not buried inside class-building
        # metaprogramming.
        def call_remote_tool(client:, tool_name:, args:, budget:, max_result_chars:)
          unless budget.consume!
            return { error: "Tool call budget exhausted (#{budget.max_calls} remote calls for this request) -- " \
                            "write your final answer with what you have so far." }
          end

          response = client.call_tool(name: tool_name, arguments: args)
          render_tool_result(response, max_result_chars:)
        rescue ::MCP::Client::ServerError => e
          { error: "Remote tool error: #{e.message}" }
        rescue ::Faraday::TimeoutError
          { error: "Remote tool call timed out" }
        rescue ::Faraday::Error, ::MCP::Client::RequestHandlerError => e
          { error: "Remote tool call failed: #{e.message}" }
        rescue StandardError => e
          # RubyLLM has no rescue around a tool's #execute (axn-ruby_llm's own ToolAdapter guard
          # exists for exactly this reason on the Axn side) -- an unanticipated MCP client error
          # here (a malformed response, a client-side bug) must not escape and break the whole chat.
          Axn.config.logger.error { "[axn-ruby_llm] remote MCP tool #{tool_name.inspect} failed: #{e.class}: #{e.message}" }
          { error: "The remote tool could not produce a valid response" }
        end

        # The MCP result shape is `{"result" => {"content" => [{"type" => "text", "text" => "..."}, ...], "isError" => bool}}`
        # (see MCP::Client#call_tool's own doc example: `response.dig("result", "content")`). Only
        # text blocks are supported for now -- Metabase's tools return text/JSON, and a truncated
        # binary block would be meaningless to the model anyway.
        def render_tool_result(response, max_result_chars:)
          result = response["result"] || {}
          text = Array(result["content"]).filter_map { |block| block["text"] }.join("\n")
          text = "#{text[0...max_result_chars]}\n... (truncated at #{max_result_chars} characters)" if text.length > max_result_chars

          return { error: text.empty? ? "Tool call failed" : text } if result["isError"]

          text
        end
      end
    end
  end
end
