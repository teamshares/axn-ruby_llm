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

    describe "#execute" do
      subject(:tool) { described_class.wrap(greeter).new }

      it "runs the Axn and returns the exposed values as a JSON-safe Hash on success" do
        expect(tool.execute(name: "Ada")).to eq("greeting" => "Hello, Ada!")
      end

      it "returns { error: } on failure, without running the tool's success path" do
        failing_tool = described_class.wrap(failer).new
        expect(failing_tool.execute(name: "nobody")).to eq(error: "Couldn't greet: no name allowed")
      end
    end

    describe "halt_after:" do
      it "wraps a successful payload in RubyLLM::Tool::Halt when true" do
        tool = described_class.wrap(greeter, halt_after: true).new
        result = tool.execute(name: "Ada")
        expect(result).to be_a(RubyLLM::Tool::Halt)
        expect(result.content).to eq("greeting" => "Hello, Ada!")
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
      it "returns the exposed values Hash by default (:structured)" do
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq("greeting" => "Hello, Ada!")
      end

      it "returns result.message when declared :text via extension_metadata" do
        greeter.set_extension_metadata(:ruby_llm, render_as: :text)
        tool = described_class.wrap(greeter).new
        expect(tool.execute(name: "Ada")).to eq("Action completed successfully")
      end
    end

    describe "declaring config via core's extension registry (set_extension_metadata)" do
      before do
        greeter.set_extension_metadata(:ruby_llm, halt_after: true, provider_params: { foo: "bar" })
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
        expect(tool.execute).to eq("company_id" => 42)
      end
    end
  end
end
