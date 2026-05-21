# frozen_string_literal: true

RSpec.describe Axn::RubyLLM::Configuration do
  after { Axn::RubyLLM.reset_configuration! }

  describe "defaults" do
    it "sets default_model to gpt-4o-mini" do
      expect(Axn::RubyLLM.configuration.default_model).to eq("gpt-4o-mini")
    end

    it "defaults enabled to true" do
      expect(Axn::RubyLLM.configuration.enabled?).to be(true)
    end
  end

  describe "Axn::RubyLLM.configure" do
    it "mutates configuration via a block" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      expect(Axn::RubyLLM.configuration.default_model).to eq("o3-mini")
    end

    it "persists across multiple accesses" do
      Axn::RubyLLM.configure { |c| c.default_model = "claude-3-haiku" }
      expect(Axn::RubyLLM.configuration.default_model).to eq("claude-3-haiku")
      expect(Axn::RubyLLM.configuration.default_model).to eq("claude-3-haiku")
    end
  end

  describe "reset_configuration!" do
    it "restores defaults" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      Axn::RubyLLM.reset_configuration!
      expect(Axn::RubyLLM.configuration.default_model).to eq("gpt-4o-mini")
    end
  end

  describe "#enabled?" do
    it "returns true for enabled = true" do
      Axn::RubyLLM.configure { |c| c.enabled = true }
      expect(Axn::RubyLLM.configuration.enabled?).to be(true)
    end

    it "returns false for enabled = false" do
      Axn::RubyLLM.configure { |c| c.enabled = false }
      expect(Axn::RubyLLM.configuration.enabled?).to be(false)
    end

    it "evaluates a callable" do
      Axn::RubyLLM.configure { |c| c.enabled = -> { false } }
      expect(Axn::RubyLLM.configuration.enabled?).to be(false)
    end
  end
end
