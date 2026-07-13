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

      it "names the tool after the axn's resolved_axn_name" do
        expect(tool_class.new.name).to eq("greet")
      end

      it "carries the axn's description" do
        expect(tool_class.description).to eq("Greets someone by name")
      end

      it "advertises the axn's input schema as tool params" do
        expected = JSON.parse(greeter.input_schema.to_json)
        expect(tool_class.new.params_schema).to eq(expected)
      end
    end

    describe "tool naming" do
      it "sanitizes a namespaced class name (no axn_name declared) into an API-safe tool name" do
        namespaced = Class.new do
          include Axn

          expects :name, type: String
          exposes :greeting

          def call
            expose greeting: "hi"
          end
        end
        stub_const("Some::Nested::Widget", namespaced)

        expect(described_class.wrap(Some::Nested::Widget).new.name).to eq("some__nested__widget")
      end

      it "sanitizes the anonymous-class fallback name" do
        anonymous = Class.new do
          include Axn

          expects :name, type: String
          exposes :greeting

          def call
            expose greeting: "hi"
          end
        end

        expect(described_class.wrap(anonymous).new.name).to eq("anonymous_axn")
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

      it "returns RubyLLM's invalid-arguments error for a missing required field, without invoking the Axn" do
        expect(greeter).not_to receive(:call)
        expect(tool.execute).to eq(error: "Invalid tool arguments: missing keyword: name")
      end

      it "returns RubyLLM's invalid-arguments error for an argument outside the schema, without invoking the Axn" do
        expect(greeter).not_to receive(:call)
        expect(tool.execute(name: "Ada", extra: "haha")).to eq(error: "Invalid tool arguments: unknown keyword: extra")
      end

      it "returns RubyLLM's invalid-arguments error for a wrong-type argument, without invoking the Axn" do
        expect(greeter).not_to receive(:call)
        expect(tool.execute(name: 123)).to eq(error: "Invalid tool arguments: name must be a string")
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

      it "rejects an ambient_context key smuggled in through tool args, without invoking the Axn" do
        tool = described_class.wrap(ambient_axn).new
        expect(ambient_axn).not_to receive(:call)
        expect(tool.execute(ambient_context: { company_id: "attacker" })).to eq(
          error: "Invalid tool arguments: unknown keyword: ambient_context",
        )
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

    describe "render_as:" do
      it "returns the exposed values as a JSON string by default (:structured)" do
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq({ "greeting" => "Hello, Ada!" }.to_json)
      end

      it "returns result.message when declared :text via configure(:ruby_llm)" do
        greeter.configure(:ruby_llm) { |c| c.render_as = :text }
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq("Action completed successfully")
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
end
