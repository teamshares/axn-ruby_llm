# frozen_string_literal: true

RSpec.describe "Axn::RubyLLM configuration" do
  after { Axn::RubyLLM.reset_config! }

  describe "defaults" do
    it "sets default_model to gpt-4o-mini" do
      expect(Axn::RubyLLM.config.default_model).to eq("gpt-4o-mini")
    end

    it "defaults enabled to true" do
      expect(Axn::RubyLLM.enabled?).to be(true)
    end

    it "defaults error_headline to 'LLM request failed'" do
      expect(Axn::RubyLLM.config.error_headline).to eq("LLM request failed")
    end
  end

  describe "Axn::RubyLLM.configure" do
    it "mutates configuration via a block" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      expect(Axn::RubyLLM.config.default_model).to eq("o3-mini")
    end

    it "persists across multiple accesses" do
      Axn::RubyLLM.configure { |c| c.default_model = "claude-3-haiku" }
      expect(Axn::RubyLLM.config.default_model).to eq("claude-3-haiku")
      expect(Axn::RubyLLM.config.default_model).to eq("claude-3-haiku")
    end
  end

  describe "reset_config!" do
    it "restores defaults" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      Axn::RubyLLM.reset_config!
      expect(Axn::RubyLLM.config.default_model).to eq("gpt-4o-mini")
    end
  end

  describe "#error_headline" do
    it "is configurable via Axn::RubyLLM.configure" do
      Axn::RubyLLM.configure { |c| c.error_headline = "Something went wrong calling the LLM" }
      expect(Axn::RubyLLM.config.error_headline).to eq("Something went wrong calling the LLM")
    end
  end

  # `Axn::RubyLLM.enabled?` is the supported reader — it resolves a callable. axn's Configurable no
  # longer invokes an assigned callable on read (PRO-3017 removed `callable:`), so the DSL-generated
  # `config.enabled?` returns a Proc as-is (truthy); the callable cases below are the regression that
  # silently re-enables gating everywhere if this reader stops resolving.
  describe ".enabled?" do
    it "is true when unset (default)" do
      expect(Axn::RubyLLM.enabled?).to be(true)
    end

    it "is false when set to false" do
      Axn::RubyLLM.configure { |c| c.enabled = false }
      expect(Axn::RubyLLM.enabled?).to be(false)
    end

    it "invokes a callable returning false" do
      Axn::RubyLLM.configure { |c| c.enabled = -> { false } }
      expect(Axn::RubyLLM.enabled?).to be(false)
    end

    it "invokes a callable returning true" do
      Axn::RubyLLM.configure { |c| c.enabled = -> { true } }
      expect(Axn::RubyLLM.enabled?).to be(true)
    end

    it "resolves the callable on each read" do
      toggle = true
      Axn::RubyLLM.configure { |c| c.enabled = -> { toggle } }
      expect(Axn::RubyLLM.enabled?).to be(true)
      toggle = false
      expect(Axn::RubyLLM.enabled?).to be(false)
    end
  end
end
