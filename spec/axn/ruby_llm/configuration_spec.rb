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

  describe "deprecated backward-compatible aliases" do
    # These aliases are scheduled for removal in the next minor version
    # (see DEPRECATIONS.md). They must keep working but warn on use.
    #
    # The warnings use `category: :deprecated`, which Ruby suppresses unless
    # deprecation warnings are enabled, so we flip Warning[:deprecated] on for
    # these examples in order to observe (and assert) the message.
    around do |example|
      previous = Warning[:deprecated]
      Warning[:deprecated] = true
      example.run
    ensure
      Warning[:deprecated] = previous
    end

    it "exposes .configuration as an alias for .config (with a deprecation warning)" do
      result = nil
      expect { result = Axn::RubyLLM.configuration }
        .to output(/DEPRECATION: Axn::RubyLLM\.configuration is deprecated.*use Axn::RubyLLM\.config instead/)
        .to_stderr
      # A backward-compatible view that delegates to the real config (see enabled? cases below).
      expect(result.default_model).to eq(Axn::RubyLLM.config.default_model)
    end

    # The pre-DSL Configuration#enabled? invoked a callable gate; the DSL predicate treats a Proc as
    # truthy. The alias must preserve the callable-resolving behavior so a compat caller's production
    # gate doesn't silently read as enabled during the deprecation window.
    it "resolves a callable gate through .configuration.enabled? (not the raw-Proc DSL predicate)" do
      Axn::RubyLLM.configure { |c| c.enabled = -> { false } }
      result = nil
      expect { result = Axn::RubyLLM.configuration.enabled? }.to output(/DEPRECATION/).to_stderr
      expect(result).to be(false)
      expect(Axn::RubyLLM.config.enabled?).to be(true) # the DSL predicate the alias must not regress to
    end

    it "supports configuring via the .configuration alias" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      result = nil
      expect { result = Axn::RubyLLM.configuration.default_model }.to output(/DEPRECATION/).to_stderr
      expect(result).to eq("o3-mini")
    end

    it "exposes reset_configuration! as an alias for reset_config! (with a deprecation warning)" do
      Axn::RubyLLM.configure { |c| c.default_model = "o3-mini" }
      expect { Axn::RubyLLM.reset_configuration! }
        .to output(/DEPRECATION: Axn::RubyLLM\.reset_configuration! is deprecated.*use Axn::RubyLLM\.reset_config! instead/)
        .to_stderr
      expect(Axn::RubyLLM.config.default_model).to eq("gpt-4o-mini")
    end

    it "stays silent by default (deprecation warnings off)" do
      Warning[:deprecated] = false
      expect { Axn::RubyLLM.configuration }.not_to output.to_stderr
    end
  end
end
