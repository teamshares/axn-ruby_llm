# frozen_string_literal: true

# Core renders each input_schema residue (a constraint the runtime enforces but JSON Schema can't
# express exactly) into the property's `description`. This adapter must deliver that prose to the
# provider unchanged and must not add its own. These specs read the JSON request body RubyLLM
# actually sends for each protocol family and compare every description against core's
# `input_schema` at the same path. Equality against core means the three tool adapters agree with
# each other without a shared cross-repo fixture.
RSpec.describe "input_schema residue descriptions on the provider wire" do
  # Records the request body, then aborts the request so nothing leaves the process.
  let(:capture_adapter) do
    Class.new(Faraday::Adapter) do
      class << self
        attr_accessor :bodies
      end

      def call(env)
        self.class.bodies << env.body
        raise Faraday::ConnectionFailed, "captured"
      end
    end
  end

  before do
    capture_adapter.bodies = []
    Faraday::Adapter.register_middleware(axn_residue_capture: capture_adapter)
  end

  # One provider per protocol family RubyLLM ships for tools, each paired with where that
  # protocol puts a tool's parameter schema in its request body.
  providers = {
    "OpenAI Responses" => [:openai, "gpt-4o", ->(tool) { tool["parameters"] }],
    "Chat Completions (OpenRouter)" => [:openrouter, "openai/gpt-4o", ->(tool) { tool.dig("function", "parameters") }],
    "Anthropic Messages" => [:anthropic, "claude-sonnet-4-5", ->(tool) { tool["input_schema"] }],
    "Gemini" => [:gemini, "gemini-2.5-flash", ->(tool) { tool.dig("functionDeclarations", 0, "parametersJsonSchema") }],
  }

  def wire_parameters(axn_class, provider:, model:, extract:)
    context = RubyLLM.context do |c|
      c.faraday_adapter = :axn_residue_capture
      c.max_retries = 0
      c.openai_api_key = c.anthropic_api_key = c.gemini_api_key = c.openrouter_api_key = "test"
    end
    chat = context.chat(model:, provider:, assume_model_exists: true).with_tools(Axn::RubyLLM.wrap(axn_class))
    expect { chat.ask("hi") }.to raise_error(StandardError)

    expect(capture_adapter.bodies.size).to eq(1)
    extract.call(JSON.parse(capture_adapter.bodies.first).fetch("tools").first)
  end

  # Every `description` in a schema, keyed by the path of schema keywords that reaches it.
  def descriptions(schema, path = [], out = {})
    case schema
    when Hash
      out[path] = schema["description"] if schema.key?("description")
      schema.each { |key, value| descriptions(value, path + [key], out) unless key == "description" }
    when Array
      schema.each_with_index { |value, i| descriptions(value, path + [i], out) }
    end
    out
  end

  def core_schema(axn_class) = JSON.parse(axn_class.input_schema.to_json)

  let(:lookup) { Class.new { def self.find(_id) = nil } }

  let(:with_residues) do
    lookup_class = lookup
    Class.new do
      include Axn

      axn_name "residue_probe"
      description "Exercises residues at the top level and nested"

      expects :code, type: String, length: { minimum: 3, if: -> { true } }
      expects :slug, type: String, format: { with: /\A[a-z]+\z/i }
      expects :meta, type: Hash
      expects :count, on: :meta, type: Integer, numericality: { greater_than: 0, if: -> { true } }
      expects :company, model: { klass: lookup_class, finder: :find, id_type: Integer }
    end
  end

  let(:without_residues) do
    Class.new do
      include Axn

      axn_name "plain_probe"
      description "No residues"

      expects :name, type: String, description: "Who to greet"
      expects :meta, type: Hash
      expects :count, on: :meta, type: Integer, numericality: { greater_than: 0 }
    end
  end

  it "has a fixture whose residues land at the top level and nested (so the comparison is not vacuous)" do
    paths = with_residues.input_schema_residues.map(&:path).uniq
    expect(paths).to contain_exactly([:code], [:slug], %i[meta count], [:company_id])

    rendered = descriptions(core_schema(with_residues))
    with_residues.input_schema_residues.each do |residue|
      key = residue.path.flat_map { |segment| ["properties", segment.to_s] }
      expect(rendered.fetch(key)).to include(residue.summary)
    end
  end

  it "has a residue-free fixture with no residue prose" do
    expect(without_residues.input_schema_residues).to be_empty
    expect(descriptions(core_schema(without_residues)).values).to eq(["Who to greet"])
  end

  providers.each do |label, (provider, model, extract)|
    describe label do
      it "delivers every residue description exactly as core rendered it, nested included" do
        wire = wire_parameters(with_residues, provider:, model:, extract:)
        expected = descriptions(core_schema(with_residues))

        expect(descriptions(wire)).to eq(expected)
        expect(expected.keys).to include(%w[properties meta properties count])
      end

      it "leaves a residue-free axn's parameters identical to core's input_schema" do
        wire = wire_parameters(without_residues, provider:, model:, extract:)

        expect(wire).to eq(core_schema(without_residues))
      end
    end
  end
end
