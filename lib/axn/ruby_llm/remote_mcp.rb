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
        #
        # Auth beyond a static `headers:` value:
        #
        # - `bearer_token:` -- a String, or a callable returning one, sent as `Authorization: Bearer
        #   <token>`. A callable runs on EVERY request (Faraday's :authorization middleware), so the
        #   caller owns caching/refresh/rotation (e.g. a token fetched from its own OAuth store).
        # - `oauth:` -- an `MCP::Client::OAuth::ClientCredentialsProvider` (machine-to-machine) or
        #   `MCP::Client::OAuth::Provider` (interactive authorization code + PKCE), passed straight to
        #   `MCP::Client::HTTP`, which runs discovery, token exchange, refresh, and the 401 retry itself.
        #
        # Either one refuses a URL that is neither https nor loopback http, so a token never crosses
        # the wire in plaintext.
        def remote_mcp_tools(url:, headers: {}, bearer_token: nil, oauth: nil, allowed_tools: nil,
                             max_calls: DEFAULT_MAX_CALLS, timeout: DEFAULT_TIMEOUT, max_result_chars: DEFAULT_MAX_RESULT_CHARS)
          raise ArgumentError, "pass bearer_token: or oauth:, not both" if bearer_token && oauth

          client = connect_client(url:, headers:, bearer_token:, oauth:, timeout:)
          remote_tools = client.tools
          remote_tools = remote_tools.select { |t| allowed_tools.include?(t.name) } if allowed_tools

          # One budget per toolset, not per tool: the limit bounds how many round-trips ONE chat makes
          # to this server in total, not how many times any single tool gets called.
          budget = ToolBudget.new(max_calls, noun: "remote calls")
          wrapped = remote_tools.map { |remote_tool| build_tool_class(remote_tool, client:, budget:, max_result_chars:) }

          Toolset.new(tools: wrapped, client:)
        end

        private

        def connect_client(url:, headers:, bearer_token:, oauth:, timeout:)
          # MCP::Client::HTTP enforces this itself for oauth:, but knows nothing about a token set by
          # the Faraday middleware below.
          raise ArgumentError, "bearer_token: requires an https (or loopback http) MCP URL" if bearer_token && !::MCP::Client::OAuth::Discovery.secure_url?(url)

          transport = ::MCP::Client::HTTP.new(url:, headers:, **{ oauth: }.compact) do |faraday|
            faraday.options.timeout = timeout
            faraday.options.open_timeout = timeout
            faraday.request :authorization, "Bearer", bearer_token if bearer_token
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
          return budget.exhausted_result unless budget.consume!

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
