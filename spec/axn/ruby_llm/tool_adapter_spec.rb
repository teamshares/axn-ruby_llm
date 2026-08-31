# frozen_string_literal: true

RSpec.describe Axn::RubyLLM do
  describe ".wrap" do
    let(:greeter) do
      Class.new do
        include Axn

        axn_name "greet"
        description "Greets someone by name"

        expects :name, type: String
        exposes :greeting

        def call
          expose greeting: "Hello, #{name}!"
        end
      end
    end

    let(:failer) do
      Class.new do
        include Axn

        expects :name, type: String
        error "Couldn't greet"

        def call
          fail! "no name allowed" if name == "nobody"
        end
      end
    end

    describe "the returned tool class" do
      subject(:tool_class) { described_class.wrap(greeter) }

      it "is a RubyLLM::Tool subclass" do
        expect(tool_class).to be < RubyLLM::Tool
      end

      it "names the tool via core's canonical tool_name" do
        # Locked to core `tool_name` (not the old crude sanitize_tool_name) so the same Axn class
        # wraps to the same provider name across every adapter (Axn::MCP.wrap included) -- PRO-2924.
        expect(tool_class.new.name).to eq("greet")
        expect(tool_class.new.name).to eq(greeter.tool_name)
      end

      it "carries the axn's description" do
        expect(tool_class.description).to eq("Greets someone by name")
      end

      it "advertises the axn's input schema as tool params" do
        expected = JSON.parse(greeter.input_schema.to_json)
        expect(tool_class.new.params_schema).to eq(expected)
      end

      it "rewrites axn's array-valued nullable type into anyOf form so Gemini keeps the real type" do
        # axn represents a nullable/optional field as `type: ["integer", "null"]`. RubyLLM's Gemini
        # converter only understands anyOf-form nullability -- it stringifies an array `type` and
        # falls through to STRING, silently dropping both the real type and the nullability. The
        # adapter normalizes array `type` to the equivalent anyOf, which every provider handles.
        nullable = Class.new do
          include Axn

          expects :count, type: Integer, optional: true
          def call; end
        end

        schema = described_class.wrap(nullable).new.params_schema
        expect(schema["properties"]["count"]).to eq(
          "anyOf" => [{ "type" => "integer" }, { "type" => "null" }],
        )
      end

      it "advertises an inclusion set as enum, and keeps it when the field is also nullable" do
        # Core reflects a top-level `inclusion:` into JSON Schema `enum` (PRO-2842). The adapter just
        # forwards input_schema, so enum flows through -- including alongside the nullable anyOf
        # rewrite for an optional field (enum stays put, type becomes anyOf).
        enum_axn = Class.new do
          include Axn

          expects :color, type: String, inclusion: { in: %w[red green blue] }
          expects :shade, type: String, inclusion: { in: %w[light dark] }, optional: true
          def call; end
        end

        props = described_class.wrap(enum_axn).new.params_schema["properties"]
        expect(props["color"]).to eq("type" => "string", "enum" => %w[red green blue], "minLength" => 1)
        expect(props["shade"]).to eq(
          "enum" => ["light", "dark", nil],
          "anyOf" => [{ "type" => "string" }, { "type" => "null" }],
        )
      end

      it "leaves RubyLLM's Parameter introspection (.parameters) empty -- the schema travels via params_schema" do
        # We feed a raw JSON Schema Hash to `params(...)`, which populates params_schema_definition
        # (what providers actually serialize -- see the params_schema assertion above) but NOT the
        # `param` DSL's Parameter objects. Argument validation is handled by the adapter's own
        # validator, so empty .parameters is correct behavior, not a missing feature (PRO-2924 #4).
        expect(tool_class.new.parameters).to eq({})
      end
    end

    describe "tool naming" do
      it "derives a clean, word-boundary-preserving name from a namespaced class via core tool_name" do
        namespaced = Class.new do
          include Axn

          expects :name, type: String
          exposes :greeting

          def call
            expose greeting: "hi"
          end
        end
        stub_const("Some::Nested::Widget", namespaced)

        # Core tool_name snake_cases each segment with single underscores (no more crude
        # "some__nested__widget" mangling), matching what Axn::MCP.wrap produces for the same class.
        expect(described_class.wrap(Some::Nested::Widget).new.name).to eq("some_nested_widget")
        expect(described_class.wrap(Some::Nested::Widget).new.name).to eq(Some::Nested::Widget.tool_name)
      end

      it "honors a per-adapter `tool ruby_llm: { name: }` override (the name the registry keys on)" do
        # Core keys registry membership, version-collapsing, and sort order for Axn::Tools.for(:ruby_llm)
        # on tool_name(:ruby_llm). The wrapper must publish that same adapter-keyed name, or a provider
        # tool call / forced choice on the declared name wouldn't match the function we advertised.
        renamed = Class.new do
          include Axn

          tool ruby_llm: { name: "search_web" }
          expects :q, type: String
          exposes :hits
          def call = expose(hits: [])
        end
        stub_const("Legacy::FindStuff", renamed)

        expect(described_class.wrap(Legacy::FindStuff).new.name).to eq("search_web")
        expect(described_class.wrap(Legacy::FindStuff).new.name).to eq(Legacy::FindStuff.tool_name(:ruby_llm))
        # ...and NOT the zero-arg name the override is meant to supersede.
        expect(Legacy::FindStuff.tool_name(:ruby_llm)).not_to eq(Legacy::FindStuff.tool_name)
      end

      it "falls back to core tool_name's never-blank default for a truly anonymous class" do
        anonymous = Class.new do
          include Axn

          expects :name, type: String
          exposes :greeting

          def call
            expose greeting: "hi"
          end
        end

        # No axn_name, no class name -> core tool_name yields "tool" (its never-blank fallback),
        # not the "Anonymous Axn" display sentinel the old sanitizer stringified.
        expect(described_class.wrap(anonymous).new.name).to eq("tool")
        expect(described_class.wrap(anonymous).new.name).to eq(anonymous.tool_name)
      end
    end

    describe "#execute" do
      subject(:tool) { described_class.wrap(greeter).new }

      it "runs the Axn and returns the exposed values as a JSON string on success" do
        expect(tool.execute(name: "Ada")).to eq({ "greeting" => "Hello, Ada!" }.to_json)
      end

      it "returns { error: } on failure, without running the tool's success path" do
        failing_tool = described_class.wrap(failer).new
        expect(failing_tool.execute(name: "nobody")).to eq(error: "Couldn't greet: no name allowed")
      end

      # The Invoker (PRO-2943) runs the Axn under user-facing input validation, so a bad tool call
      # surfaces as a clean, correctable "Invalid tool arguments: <axn message>" (and never pages
      # on_exception), rather than the adapter pre-checking a shallow subset of the schema itself.
      it "returns an invalid-arguments error for a missing required field" do
        expect(tool.execute).to eq(error: "Invalid tool arguments: Name is not a String")
      end

      it "returns an invalid-arguments error for an argument outside the schema" do
        expect(tool.execute(name: "Ada", extra: "haha")).to eq(error: "Invalid tool arguments: unknown input: extra")
      end

      it "returns an invalid-arguments error for a wrong-type argument (full-depth, not just top-level)" do
        expect(tool.execute(name: 123)).to eq(error: "Invalid tool arguments: Name is not a String")
      end

      it "returns an invalid-arguments error for a value outside an inclusion set" do
        enum_axn = Class.new do
          include Axn

          expects :color, type: String, inclusion: %w[red green blue]
          exposes :chosen
          def call = expose(chosen: color)
        end
        tool = described_class.wrap(enum_axn).new
        expect(tool.execute(color: "purple")).to eq(error: "Invalid tool arguments: Color is not included in the list")
      end

      it "allows a nil value for an optional (nullable) field" do
        optional_axn = Class.new do
          include Axn

          expects :name, type: String
          expects :nickname, type: String, optional: true
          exposes :greeting

          def call
            expose greeting: nickname ? "Hello, #{nickname}!" : "Hello, #{name}!"
          end
        end

        tool = described_class.wrap(optional_axn).new
        expect(tool.execute(name: "Ada", nickname: nil)).to eq({ "greeting" => "Hello, Ada!" }.to_json)
      end
    end

    describe "security: a provider-supplied ambient_context must never override the caller's context" do
      let(:ambient_axn) do
        Class.new do
          include Axn

          expects :company_id, on: :ambient_context
          exposes :company_id

          def call
            expose company_id:
          end
        end
      end

      it "strips a model-supplied ambient_context; the wrap's trusted context wins" do
        # The Invoker treats ambient_context as reserved: a value smuggled in through tool args is
        # dropped before the Axn runs, and the wrap's own trusted context is injected instead — so the
        # attacker value never reaches the Axn.
        tool = described_class.wrap(ambient_axn, ambient_context: { company_id: 42 })
        expect(tool.execute(ambient_context: { company_id: "attacker" })).to eq({ "company_id" => 42 }.to_json)
      end
    end

    describe "serialization failures surface as a tool error, not an escaping exception" do
      # RubyLLM has no rescue around a tool's #execute, so an unhandled raise here would break the
      # whole chat. Both of core's serialize paths can raise, and both must become a tool error.

      it "maps a core-unserializable value (colliding JSON keys) to a tool error" do
        klass = Class.new do
          include Axn

          exposes :rec
          def call = expose(rec: { id: 1, "id" => 2 })
        end

        expect { described_class.wrap(klass).new.execute }.not_to raise_error
        expect(described_class.wrap(klass).new.execute).to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
      end

      it "maps a structure past the JSON encoder's max_nesting to a tool error" do
        klass = Class.new do
          include Axn

          exposes :deep
          def call
            root = leaf = {}
            130.times do
              node = {}
              leaf["k"] = node
              leaf = node
            end
            expose(deep: root)
          end
        end

        expect(described_class.wrap(klass).new.execute).to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
      end
    end

    describe "transport-failure guard (upholds axn's non-bang never-raises at the adapter boundary)" do
      # A value with no honest JSON form makes serialization raise AFTER the Axn already succeeded --
      # in the transport step, outside core's executor (the gap core's own on_exception doesn't
      # cover). The guard turns that into a tool error + a global on_exception report; the existing
      # "serialization failures surface as a tool error" specs above cover the no-raise/error-return
      # side, so these cover the reporting + dev-reraise + any-StandardError side (axn-mcp parity).
      let(:dup_key_axn) do
        Class.new do
          include Axn

          def self.name = "GuardDupKey"

          exposes :rec
          def call = expose(rec: { id: 1, "id" => 2 })
        end
      end

      it "reports the failure through axn's global on_exception hook (observability, not silent)" do
        captured = nil
        allow(Axn.config).to receive(:on_exception) { |e, **| captured = e }

        described_class.wrap(dup_key_axn).new.execute

        expect(captured).to be_a(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "re-raises rather than swallowing when core's raises_in_dev? is on (bugs surface loudly)" do
        allow(Axn::Extensions).to receive(:raises_in_dev?).and_return(true)

        expect { described_class.wrap(dup_key_axn).new.execute }
          .to raise_error(Axn::Extensions::Serialization::UnserializableValue)
      end

      it "guards ANY StandardError from the mapping step, not only serialization" do
        allow(Axn::Extensions::Serialization).to receive(:render).and_raise(RuntimeError, "boom")
        captured = nil
        allow(Axn.config).to receive(:on_exception) { |e, **| captured = e }

        response = described_class.wrap(dup_key_axn).new.execute

        expect(response).to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
        expect(captured).to be_a(RuntimeError)
      end

      it "still returns the tool error when the on_exception reporter itself raises (best-effort)" do
        # The reporter is app-configured and can raise; core invokes it inside best_effort, we call it
        # directly, so the guard must wrap it -- else a raising reporter escapes and aborts the chat.
        allow(Axn.config).to receive(:on_exception).and_raise(RuntimeError, "reporter boom")

        expect { described_class.wrap(dup_key_axn).new.execute }.not_to raise_error
        expect(described_class.wrap(dup_key_axn).new.execute)
          .to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
      end

      # The tool-facing error stays generic; this log line is an operator's only pointer to WHY. Mirrors
      # axn-openapi's dispatcher hint spec / axn-mcp's Invocation guard spec: named because
      # reject_opaque_exposed_values is overridable, so a hint naming only the gem-wide setter is a dead
      # end whenever a per-tool override is what's in effect.
      describe "the opaque-rejection log hint" do
        def captured_log_for(axn_class)
          io = StringIO.new
          allow(Axn.config).to receive(:logger).and_return(Logger.new(io))
          described_class.wrap(axn_class).new.execute
          io.string
        end

        it "names the offending tool and BOTH config levels when reject_opaque_exposed_values is on" do
          opaque_axn = Class.new do
            include Axn

            def self.name = "ToolAdapterSpec::Opaque"

            configure(:ruby_llm) { |c| c.reject_opaque_exposed_values = true }
            exposes :thing
            def call = expose(thing: Object.new)
          end

          line = captured_log_for(opaque_axn)

          expect(line).to include("ToolAdapterSpec::Opaque")
          expect(line).to include("configure(:ruby_llm)")
          expect(line).to include("Axn::RubyLLM.config.reject_opaque_exposed_values")
        end

        it "omits the hint when reject_opaque_exposed_values is off (the rejection can't be opaque-related)" do
          line = captured_log_for(dup_key_axn)

          expect(line).to include("UnserializableValue")
          expect(line).not_to include("reject_opaque_exposed_values")
        end
      end
    end

    describe "reject_opaque_exposed_values" do
      # An exposed value with no author-declared JSON form: no to_json/as_json, so it can only render
      # as an opaque blob ("#<OpaqueValue:0x…>").
      let(:opaque_axn) do
        Class.new do
          include Axn

          exposes :obj
          def call = expose(obj: OpaqueValue.new)
        end
      end

      before { stub_const("OpaqueValue", Class.new) }
      after { Axn::RubyLLM.reset_config! }

      it "ships the opaque rendering by default (false)" do
        payload = described_class.wrap(opaque_axn).new.execute
        expect(payload).to be_a(String)
        expect(JSON.parse(payload)["obj"]).to be_a(String).and include("OpaqueValue")
      end

      it "surfaces a tool error (not an escaping raise) when enabled gem-wide" do
        Axn::RubyLLM.configure { |c| c.reject_opaque_exposed_values = true }

        expect { described_class.wrap(opaque_axn).new.execute }.not_to raise_error
        expect(described_class.wrap(opaque_axn).new.execute).to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
      end

      it "honors a per-class configure(:ruby_llm) override" do
        opaque_axn.configure(:ruby_llm) { |c| c.reject_opaque_exposed_values = true }

        expect(described_class.wrap(opaque_axn).new.execute).to eq(error: Axn::RubyLLM::ToolAdapter::ADAPTER_FAILURE_MESSAGE)
      end

      it "lets a per-class false beat a gem-wide true (per-class wins)" do
        Axn::RubyLLM.configure { |c| c.reject_opaque_exposed_values = true }
        opaque_axn.configure(:ruby_llm) { |c| c.reject_opaque_exposed_values = false }

        payload = described_class.wrap(opaque_axn).new.execute
        expect(payload).to be_a(String)
        expect(JSON.parse(payload)["obj"]).to include("OpaqueValue")
      end
    end

    describe "halt_after:" do
      it "wraps a successful payload in RubyLLM::Tool::Halt when true" do
        tool = described_class.wrap(greeter, halt_after: true).new
        result = tool.execute(name: "Ada")
        expect(result).to be_a(RubyLLM::Tool::Halt)
        expect(result.content).to eq({ "greeting" => "Hello, Ada!" }.to_json)
      end

      it "does not halt by default" do
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).not_to be_a(RubyLLM::Tool::Halt)
      end
    end

    describe "provider_params:" do
      it "sets the tool's provider_params via with_params" do
        tool_class = described_class.wrap(greeter, provider_params: { safety_identifier: "abc" })
        expect(tool_class.provider_params).to eq(safety_identifier: "abc")
      end

      it "defaults to an empty Hash" do
        tool_class = described_class.wrap(greeter)
        expect(tool_class.provider_params).to eq({})
      end
    end

    describe "present_as:" do
      it "returns the exposed values as a JSON string by default (:structured)" do
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq({ "greeting" => "Hello, Ada!" }.to_json)
      end

      it "returns result.message when declared :message via configure(:ruby_llm)" do
        greeter.configure(:ruby_llm) { |c| c.present_as = :message }
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq("Action completed successfully")
      end

      it "returns result.message when passed present_as: :message per-call" do
        tool = described_class.wrap(greeter, present_as: :message).new
        expect(tool.execute(name: "Ada")).to eq("Action completed successfully")
      end
    end

    describe "the renamed render_as: kwarg (pre-1.0 hard drop)" do
      it "raises a pointed migration error when render_as: is passed" do
        expect { described_class.wrap(greeter, render_as: :text) }
          .to raise_error(ArgumentError, /`render_as:` was renamed to `present_as:`.*`:text` value to `:message`/m)
      end

      it "points :text at :message when passed as present_as:" do
        expect { described_class.wrap(greeter, present_as: :text) }
          .to raise_error(ArgumentError, /present_as must be one of :structured, :message.*`:text` value was renamed to `:message`/m)
      end
    end

    describe "declaring config via axn's namespaced per-class configure(:ruby_llm)" do
      before do
        greeter.configure(:ruby_llm) do |c|
          c.halt_after = true
          c.provider_params = { foo: "bar" }
        end
      end

      it "honors the declared halt_after" do
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to be_a(RubyLLM::Tool::Halt)
      end

      it "honors the declared provider_params" do
        tool_class = described_class.wrap(greeter)
        expect(tool_class.provider_params).to eq(foo: "bar")
      end

      it "lets an explicit wrap() kwarg override the declared metadata" do
        tool = described_class.wrap(greeter, halt_after: false).new
        expect(tool.execute(name: "Ada")).not_to be_a(RubyLLM::Tool::Halt)
      end
    end

    describe "composing multiple adapter namespaces on one base Axn" do
      it "does not collide with a same-named setting configured under a different namespace" do
        greeter.configure(:ruby_llm) { |c| c.halt_after = true }
        greeter.configure(:mcp) { |c| c.halt_after = "unrelated value from a different adapter's namespace" }

        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to be_a(RubyLLM::Tool::Halt)
      end
    end

    describe "ambient_context:" do
      let(:ambient_axn) do
        Class.new do
          include Axn

          expects :company_id, on: :ambient_context
          exposes :company_id

          def call
            expose company_id:
          end
        end
      end

      it "returns the Class itself when no ambient_context is given" do
        expect(described_class.wrap(ambient_axn)).to be_a(Class)
      end

      it "returns an instance (closing over the explicit context) when ambient_context is given" do
        wrapped = described_class.wrap(ambient_axn, ambient_context: { company_id: 42 })
        expect(wrapped).to be_a(RubyLLM::Tool)
        expect(wrapped).not_to be_a(Class)
      end

      it "threads the closed-over ambient_context into every call" do
        tool = described_class.wrap(ambient_axn, ambient_context: { company_id: 42 })
        expect(tool.execute).to eq({ "company_id" => 42 }.to_json)
      end
    end
  end

  describe "tool registry integration" do
    it "registers :ruby_llm as a tool adapter at load" do
      expect(Axn::Tools::Registry.adapters).to include(:ruby_llm)
    end

    it "registers Axn::RubyLLM itself as the adapter's config source (PRO-2948)" do
      expect(Axn::Tools::Registry.adapter_config_source(:ruby_llm)).to eq(Axn::RubyLLM)
    end

    it "ships the shared agent-tools dir as the default tool_roots (PRO-2948)" do
      expect(Axn::RubyLLM.config.tool_roots).to eq(["agent_tools"])
    end

    it "rejects a broad tool_roots entry that would bulk-expose every action" do
      expect { Axn::RubyLLM.configure { |c| c.tool_roots = ["app"] } }.to raise_error(ArgumentError, /too broad/)
    ensure
      Axn::RubyLLM.reset_config!
    end

    it "enumerates Axns that opt in via `tool :ruby_llm`" do
      widget = Class.new do
        include Axn

        tool :ruby_llm
        def call; end
      end
      stub_const("RegistryViaTool::Widget", widget)

      expect(Axn::Tools.for(:ruby_llm)).to include(RegistryViaTool::Widget)
    end

    it "enumerates Axns that opt in implicitly via configure(:ruby_llm)" do
      widget = Class.new do
        include Axn

        configure(:ruby_llm) { |c| c.halt_after = true }
        def call; end
      end
      stub_const("RegistryViaConfig::Widget", widget)

      expect(Axn::Tools.for(:ruby_llm)).to include(RegistryViaConfig::Widget)
    end
  end

  describe ".tools" do
    it "returns wrapped, ready-to-register RubyLLM tools for every :ruby_llm member" do
      widget = Class.new do
        include Axn

        tool :ruby_llm
        description "does a thing"
        expects :x, type: String
        def call; end
      end
      stub_const("ToolsHelper::Widget", widget)

      tools = described_class.tools
      expect(tools).to all(be < RubyLLM::Tool)
      expect(tools.map { |t| t.new.name }).to include(ToolsHelper::Widget.tool_name)
    end

    it "returns tools in deterministic tool_name order (core sorts Axn::Tools.for, PRO-2933)" do
      %w[Zebra Alpha Mango].each do |n|
        stub_const("SortCheck::#{n}", Class.new do
          include Axn

          tool :ruby_llm
          def call; end
        end)
      end

      names = described_class.tools.map { |t| t.new.name }
      expect(names).to eq(names.sort)
    end

    it "wraps only the latest version when two versions share a tool_name (PRO-2955)" do
      stub_const("AgentTools::Thing::V1", Class.new do
        include Axn

        tool :ruby_llm
        tool_version 1
        description "thing v1"
        def call; end
      end)
      stub_const("AgentTools::Thing::V2", Class.new do
        include Axn

        tool :ruby_llm
        tool_version 2
        description "thing v2"
        def call; end
      end)

      # Both versions share tool_name "thing"; Axn::Tools.for returns the latest per name, so .tools
      # wraps only V2 (asserted via V2's distinct description, since the wrap reads it off the Axn).
      thing = described_class.tools.select { |t| t.new.name == "thing" }
      expect(thing.size).to eq(1)
      expect(thing.first.description).to eq("thing v2")
    end
  end
end
