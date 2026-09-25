# frozen_string_literal: true

# Guards Ask's pass-through surface against drift as RubyLLM evolves. Renovate bumps ruby_llm in
# Gemfile.lock; when a release adds, removes, or re-signatures a public RubyLLM::Chat method, this
# fails and names it. To resolve: forward it from Ask (and add it to `covered`), or record why not in
# `skipped`, then refresh the snapshot below.
RSpec.describe "RubyLLM::Chat parity" do
  # Chat method => the Ask inputs that drive it.
  let(:covered) do
    {
      initialize: %i[model provider protocol assume_model_exists context],
      with_model: %i[model provider protocol assume_model_exists], # via Chat.new, which calls it
      with_context: %i[context], # via Chat.new(context:)
      ask: %i[prompt attachments on_chunk],
      "messages=": %i[history],
      with_instructions: %i[system_prompt cache_system_prompt],
      with_schema: %i[schema],
      with_temperature: %i[temperature],
      with_max_output_tokens: %i[max_output_tokens],
      with_thinking: %i[thinking],
      with_citations: %i[citations],
      with_caching: %i[caching],
      with_compaction: %i[compaction],
      with_fallbacks: %i[fallbacks fallback_on],
      with_end_user: %i[end_user],
      with_provider_options: %i[provider_options],
      with_headers: %i[headers],
      with_tools: %i[tools max_tool_calls],
      with_provider_tools: %i[provider_tools],
      with_tool_options: %i[tool_options],
      complete: %i[on_remote_tool_approval on_chunk],
      awaiting_approval?: %i[on_remote_tool_approval],
      pending_approvals: %i[on_remote_tool_approval],
      approve: %i[on_remote_tool_approval],
      deny: %i[on_remote_tool_approval],
    }
  end

  let(:skipped) do
    callbacks = "per-round lifecycle hook; Axn tools already get axn's own per-call hooks, " \
                "and on_chunk/transcript cover streaming and inspection -- drive Chat directly if needed"
    loop_control = "manual loop control -- Ask runs one prompt to a final answer; drive Chat directly"
    rails_hook = "Rails-integration hook (:nodoc:)"
    reader = "reader; its value is surfaced via Ask's exposures (raw_message/transcript/tokens/cost) or is an Ask input already"

    {
      say: "alias of #ask",
      before_message: callbacks, after_message: callbacks, before_tool_call: callbacks,
      after_tool_result: callbacks, before_fallback: callbacks, after_fallback: callbacks,
      before_request: callbacks,
      ask_later: loop_control, step: loop_control, generate: loop_control, run_tools: loop_control,
      add_completion: loop_control, compact: loop_control, raise_if_pending_tool_calls!: loop_control,
      add_message: "history: seeds via messages=, which covers the same need",
      cache_until_here: "mid-conversation cache boundary; cache_system_prompt: covers the system prompt case",
      cancel: "no hook from inside a synchronous Ask; revisit with a real caller",
      cancelled?: "pairs with #cancel",
      count_tokens: "a separate operation, not part of a completion",
      render: "prompt-template rendering (RubyLLM.render_prompt); callers render into prompt: themselves",
      each: "Enumerable over messages; transcript covers it",
      "approval_checker=": rails_hook, "cancellation_checker=": rails_hook, "usage_recorder=": rails_hook,
      "usage_entries=": rails_hook,
      tokens: reader, cost: reader, messages: reader, usage_entries: reader, model: reader, provider: reader,
      context: reader, schema: reader, temperature: reader, max_output_tokens: reader, thinking: reader,
      citations: reader, caching: reader, compaction: reader, end_user: reader, headers: reader,
      provider_options: reader, provider_tools: reader, tools: reader, tool_options: reader, tool_prefs: reader,
      concurrency: reader, fallbacks: reader, fallback_errors: reader, complete?: reader
    }
  end

  # Parameter lists of every `covered` method (enforced below). A new keyword here (e.g.
  # with_instructions gaining an option) is a new capability Ask may want to expose; a changed one
  # (e.g. approve taking a keyword) breaks a call Ask makes.
  let(:signature_snapshot) do
    {
      initialize: [%i[key model], %i[key provider], %i[key protocol], %i[key assume_model_exists], %i[key context]],
      ask: [%i[opt message], %i[key with], %i[block &]],
      complete: [%i[block &]],
      "messages=": [%i[req new_messages]],
      with_instructions: [%i[req instructions], %i[key append], %i[key cache_until_here]],
      with_schema: [%i[req schema]],
      with_temperature: [%i[req temperature]],
      with_max_output_tokens: [%i[req max_output_tokens]],
      with_thinking: [%i[opt enabled], %i[keyrest options]],
      with_citations: [%i[opt enabled]],
      with_caching: [%i[opt options]],
      with_compaction: [%i[opt options]],
      with_fallbacks: [%i[rest models], %i[key on]],
      with_end_user: [%i[req end_user]],
      with_provider_options: [%i[req provider_options]],
      with_headers: [%i[req headers]],
      with_tools: [%i[rest tools]],
      with_provider_tools: [%i[rest tools], %i[keyrest tools_with_options]],
      with_tool_options: [%i[keyrest options]],
      with_model: [%i[req model_id], %i[key provider], %i[key protocol], %i[key assume_model_exists]],
      with_context: [%i[req context]],
      approve: [%i[req tool_call]],
      deny: [%i[req tool_call]],
      awaiting_approval?: [],
      pending_approvals: [],
    }
  end

  let(:chat_methods) { RubyLLM::Chat.public_instance_methods(false) + [:initialize] }

  it "classifies every public RubyLLM::Chat method as covered or intentionally skipped" do
    unclassified = chat_methods - covered.keys - skipped.keys
    expect(unclassified).to be_empty, "New RubyLLM::Chat methods: #{unclassified.sort.inspect} -- forward from Ask or add to `skipped`"
  end

  it "lists no methods RubyLLM::Chat no longer has" do
    expect((covered.keys + skipped.keys) - chat_methods).to be_empty
  end

  it "never classifies a method as both covered and skipped" do
    expect(covered.keys & skipped.keys).to be_empty
  end

  it "maps every covered method to inputs Ask actually declares" do
    declared = Axn::RubyLLM::Ask.input_schema[:properties].keys
    expect(covered.values.flatten.uniq - declared).to be_empty
  end

  it "snapshots the signature of every covered method" do
    expect(covered.keys - signature_snapshot.keys).to be_empty
  end

  it "matches the snapshotted signatures of the methods Ask calls" do
    actual = signature_snapshot.keys.to_h { |m| [m, RubyLLM::Chat.instance_method(m).parameters] }
    expect(actual).to eq(signature_snapshot)
  end

  # The usage ledger (Chat#tokens) and final Message are Ask's other RubyLLM surfaces: a new usage
  # bucket or message field fails here the same way a new Chat method does above.
  describe "RubyLLM::Tokens and RubyLLM::Message coverage" do
    let(:tokens_covered) do
      { input: "uncached_input_tokens / total_input_tokens", output: "output_tokens", cache_read: "cache_read_tokens",
        cache_write: "cache_write_tokens", thinking: "thinking_tokens", server_tool_use: "server_tool_use" }
    end
    let(:tokens_skipped) do
      { reported_cost: "already reflected in cost (Cost#total prefers the provider-reported cost)",
        to_h: "serialization", inspect_attributes: "inspect support" }
    end

    let(:message_covered) do
      { content: "response", parsed: "response (schema:)", model: "OTel gen_ai.response.model",
        finish_reason: "finish_reason", max_tokens?: "fails the call", content_filtered?: "fails the call",
        role: "transcript", tool_calls: "transcript", tool_call_id: "transcript", server_tool_calls: "transcript" }
    end
    let(:message_skipped) do
      via_raw = "reachable as raw_message.<name>; no summary exposure needed"
      { citations: via_raw, thinking: via_raw, raw: via_raw, raw_content: via_raw, raw_reasoning: via_raw,
        attachments: via_raw, tokens: "per-message; Ask reports the chat-wide ledger instead",
        cost: "per-message; Ask reports the chat-wide cost instead", stopped?: "implied by finish_reason",
        tool_call?: "implied by tool_calls", tool_call_stop?: "implied by finish_reason",
        tool_result?: "implied by tool_call_id", tool_results: "transcript covers it",
        conversation: "Rails-integration link", "conversation=": "Rails-integration link",
        model_info: "registry metadata", "model_info=": "registry metadata",
        cache_until_here: "request-side cache boundary, not a response field", cache_until_here?: "request-side cache boundary",
        to_h: "serialization", with_attachments: "builder", without_thinking: "builder" }
    end

    it "classifies every public RubyLLM::Tokens method" do
      methods = RubyLLM::Tokens.public_instance_methods(false)
      expect(methods - tokens_covered.keys - tokens_skipped.keys).to be_empty
      expect((tokens_covered.keys + tokens_skipped.keys) - methods).to be_empty
    end

    it "classifies every public RubyLLM::Message method" do
      methods = RubyLLM::Message.public_instance_methods(false)
      expect(methods - message_covered.keys - message_skipped.keys).to be_empty
      expect((message_covered.keys + message_skipped.keys) - methods).to be_empty
    end

    it "exposes every covered Tokens field on Ask" do
      exposed = Axn::RubyLLM::Ask.external_field_configs.map(&:field)
      expected = %i[uncached_input_tokens total_input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens server_tool_use]
      expect(expected - exposed).to be_empty
    end
  end

  # Ask forwards these option Hashes verbatim, so a new key already works -- this only flags that the
  # README's list of keys (Chat options table) needs the new one.
  it "matches the snapshotted option keys for thinking: and compaction:" do
    expect(RubyLLM::Chat.const_get(:THINKING_OPTIONS)).to eq(%i[effort budget display])
    expect(RubyLLM::Chat::COMPACTION_OPTIONS).to eq(%i[at instructions pause_after])
  end
end
