# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::ToolBudget do
  subject(:budget) { described_class.new(2) }

  it "allows max_calls calls, then refuses" do
    expect(Array.new(3) { budget.consume! }).to eq([true, true, false])
  end

  it "stays exact under concurrent consumers" do
    budget = described_class.new(50)
    allowed = Array.new(10) { Thread.new { Array.new(20) { budget.consume! }.count(true) } }.sum(&:value)
    expect(allowed).to eq(50)
  end

  it "names the budget's noun in the exhausted result" do
    expect(described_class.new(3, noun: "remote calls").exhausted_result[:error])
      .to eq("Tool call budget exhausted (3 remote calls allowed) -- write your final answer with what you have so far.")
  end

  describe "#guard" do
    let(:tool_class) do
      Class.new(RubyLLM::Tool) do
        def self.name = "Echo"
        parameters({ type: "object", properties: { text: { type: "string" } }, required: ["text"] })
        def execute(text:) = text
      end
    end

    it "forwards arguments to the tool while the budget lasts" do
      tool = budget.guard(tool_class)
      expect(tool.call(text: "hi")).to eq("hi")
    end

    it "keeps RubyLLM's own argument validation" do
      expect(budget.guard(tool_class).call[:error]).to start_with("Invalid tool arguments")
    end
  end
end
