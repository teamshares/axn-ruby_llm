# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::RemoteMcp do
  let(:search_tool) { instance_double(MCP::Client::Tool, name: "search", description: "Search", input_schema: { "type" => "object", "properties" => {} }) }
  let(:execute_sql_tool) do
    instance_double(MCP::Client::Tool, name: "execute_sql", description: "Run SQL",
                                       input_schema: { "type" => "object", "properties" => { "sql" => { "type" => "string" } } })
  end
  let(:create_dashboard_tool) { instance_double(MCP::Client::Tool, name: "create_dashboard", description: "Create a dashboard", input_schema: {}) }
  let(:remote_tools) { [search_tool, execute_sql_tool, create_dashboard_tool] }

  let(:transport) { instance_double(MCP::Client::HTTP, close: nil) }
  let(:client) { instance_double(MCP::Client, transport:, connect: nil, tools: remote_tools) }

  before do
    allow(MCP::Client::HTTP).to receive(:new).and_return(transport)
    allow(MCP::Client).to receive(:new).with(transport:).and_return(client)
  end

  describe ".remote_mcp_tools" do
    it "connects an MCP::Client::HTTP transport with the given url and headers" do
      expect(MCP::Client::HTTP).to receive(:new).with(url: "https://example.com/mcp", headers: { "X-API-KEY" => "secret" })
      described_class.remote_mcp_tools(url: "https://example.com/mcp", headers: { "X-API-KEY" => "secret" })
    end

    describe "auth beyond static headers" do
      # Runs the Faraday customizer block remote_mcp_tools hands MCP::Client::HTTP against a real
      # connection, so the assertion is on the Authorization header actually sent.
      def sent_authorization(**options)
        customizer = nil
        allow(MCP::Client::HTTP).to receive(:new) do |**, &block|
          customizer = block
          transport
        end
        described_class.remote_mcp_tools(url: "https://example.com/mcp", **options)

        seen = []
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.post("/mcp") { |env| [200, {}, seen << env.request_headers["Authorization"]] }
        connection = Faraday.new(url: "https://example.com") do |f|
          customizer.call(f)
          f.adapter :test, stubs
        end
        2.times { connection.post("/mcp") }
        seen
      end

      it "sends a static bearer_token: String as Authorization: Bearer" do
        expect(sent_authorization(bearer_token: "abc")).to eq(["Bearer abc", "Bearer abc"])
      end

      it "calls a bearer_token: callable on every request, so the caller can rotate it" do
        tokens = %w[first second].each
        expect(sent_authorization(bearer_token: -> { tokens.next })).to eq(["Bearer first", "Bearer second"])
      end

      it "refuses a bearer_token: over plain http to a non-loopback host" do
        expect { described_class.remote_mcp_tools(url: "http://example.com/mcp", bearer_token: "abc") }
          .to raise_error(ArgumentError, /https/)
      end

      it "passes oauth: through to MCP::Client::HTTP" do
        provider = instance_double(MCP::Client::OAuth::ClientCredentialsProvider)
        expect(MCP::Client::HTTP).to receive(:new).with(url: "https://example.com/mcp", headers: {}, oauth: provider).and_return(transport)
        described_class.remote_mcp_tools(url: "https://example.com/mcp", oauth: provider)
      end

      it "rejects bearer_token: and oauth: together" do
        provider = instance_double(MCP::Client::OAuth::ClientCredentialsProvider)
        expect { described_class.remote_mcp_tools(url: "https://example.com/mcp", bearer_token: "abc", oauth: provider) }
          .to raise_error(ArgumentError, "pass bearer_token: or oauth:, not both")
      end
    end

    it "connects the client" do
      expect(client).to receive(:connect)
      described_class.remote_mcp_tools(url: "https://example.com/mcp")
    end

    it "wraps every remote tool as a ::RubyLLM::Tool subclass when no allowlist is given" do
      toolset = described_class.remote_mcp_tools(url: "https://example.com/mcp")
      expect(toolset.tools.map { |t| t.new.name }).to contain_exactly("search", "execute_sql", "create_dashboard")
      expect(toolset.tools).to all(be < RubyLLM::Tool)
    end

    it "keeps only the allowed tools -- e.g. excluding a write tool like create_dashboard" do
      toolset = described_class.remote_mcp_tools(url: "https://example.com/mcp", allowed_tools: %w[search execute_sql])
      expect(toolset.tools.map { |t| t.new.name }).to contain_exactly("search", "execute_sql")
    end

    it "sets each tool's description and parameters from the remote tool's own contract" do
      toolset = described_class.remote_mcp_tools(url: "https://example.com/mcp", allowed_tools: %w[execute_sql])
      tool = toolset.tools.first.new
      expect(tool.description).to eq("Run SQL")
      expect(tool.parameters_schema.dig("properties", "sql")).to be_present
    end

    it "returns a Toolset whose #close closes the transport" do
      toolset = described_class.remote_mcp_tools(url: "https://example.com/mcp")
      expect(transport).to receive(:close)
      toolset.close
    end
  end

  describe "a wrapped tool's #execute" do
    subject(:tool) { described_class.remote_mcp_tools(url: "https://example.com/mcp", allowed_tools: %w[execute_sql]).tools.first.new }

    let(:success_response) { { "result" => { "content" => [{ "type" => "text", "text" => "1 row" }] } } }

    before do
      allow(client).to receive(:call_tool).and_return(success_response)
    end

    it "calls the remote tool by name with the model's arguments" do
      expect(client).to receive(:call_tool).with(name: "execute_sql", arguments: { sql: "select 1" })
      tool.execute(sql: "select 1")
    end

    it "joins text content blocks and returns them as the tool result" do
      expect(tool.execute(sql: "select 1")).to eq("1 row")
    end

    it "joins multiple text content blocks with a newline" do
      allow(client).to receive(:call_tool).and_return(
        { "result" => { "content" => [{ "type" => "text", "text" => "line 1" }, { "type" => "text", "text" => "line 2" }] } },
      )
      expect(tool.execute(sql: "select 1")).to eq("line 1\nline 2")
    end

    it "truncates a result longer than max_result_chars" do
      toolset = described_class.remote_mcp_tools(url: "https://example.com/mcp", allowed_tools: %w[execute_sql], max_result_chars: 10)
      allow(client).to receive(:call_tool).and_return({ "result" => { "content" => [{ "type" => "text", "text" => "x" * 100 }] } })

      result = toolset.tools.first.new.execute(sql: "select 1")
      expect(result.length).to be < 100
      expect(result).to start_with("x" * 10)
      expect(result).to include("truncated")
    end

    context "when the server reports a tool-level error (isError)" do
      before do
        allow(client).to receive(:call_tool).and_return(
          { "result" => { "content" => [{ "type" => "text", "text" => "relation \"foo\" does not exist" }], "isError" => true } },
        )
      end

      it "returns an error Hash instead of the text" do
        expect(tool.execute(sql: "select bad")).to eq({ error: "relation \"foo\" does not exist" })
      end
    end

    context "when the server raises a JSON-RPC error" do
      before { allow(client).to receive(:call_tool).and_raise(MCP::Client::ServerError.new("not found", code: -32_601)) }

      it "returns an error Hash, not a raised exception" do
        expect(tool.execute(sql: "select 1")).to eq({ error: "Remote tool error: not found" })
      end
    end

    context "when the call times out" do
      before { allow(client).to receive(:call_tool).and_raise(Faraday::TimeoutError.new("execution expired")) }

      it "returns a timeout error Hash" do
        expect(tool.execute(sql: "select 1")).to eq({ error: "Remote tool call timed out" })
      end
    end

    context "when an unanticipated error occurs (e.g. a client-side bug)" do
      before { allow(client).to receive(:call_tool).and_raise(StandardError.new("undefined method 'foo' for nil")) }

      it "returns a generic error Hash rather than letting the exception escape and break the chat" do
        expect(tool.execute(sql: "select 1")).to eq({ error: "The remote tool could not produce a valid response" })
      end
    end

    context "once the call budget is exhausted" do
      subject(:toolset) { described_class.remote_mcp_tools(url: "https://example.com/mcp", allowed_tools: %w[execute_sql], max_calls: 2) }

      it "lets exactly max_calls calls through, then short-circuits without calling the server" do
        tool_instance = toolset.tools.first.new
        2.times { tool_instance.execute(sql: "select 1") }

        expect(client).not_to receive(:call_tool)
        expect(tool_instance.execute(sql: "select 1")).to eq({ error: "Tool call budget exhausted (2 remote calls for this request) -- " \
                                                                      "write your final answer with what you have so far." })
      end

      it "shares the budget across every tool the toolset wraps, not one budget per tool" do
        all_tool = described_class.remote_mcp_tools(url: "https://example.com/mcp", max_calls: 1)
        search = all_tool.tools.find { |t| t.new.name == "search" }.new
        sql = all_tool.tools.find { |t| t.new.name == "execute_sql" }.new
        allow(client).to receive(:call_tool).and_return(success_response)

        search.execute
        expect(client).not_to receive(:call_tool)
        expect(sql.execute(sql: "select 1")[:error]).to include("budget exhausted")
      end
    end
  end
end
