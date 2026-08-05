# Deprecations

A living list of deprecated APIs scheduled for removal. When you deprecate something, add a row here with its replacement, where it lives, and the version it will be removed in. When you remove it, delete the row (the CHANGELOG records the removal).

## Scheduled for removal

| Deprecated API | Replacement | Location | Deprecated in | Remove in |
| -------------- | ----------- | -------- | ------------- | --------- |
| `Axn::RubyLLM.configuration` | `Axn::RubyLLM.config` | `lib/axn/ruby_llm.rb` (`def configuration`, ~line 24) | 0.2.0 | 0.3.0 |
| `Axn::RubyLLM.reset_configuration!` | `Axn::RubyLLM.reset_config!` | `lib/axn/ruby_llm.rb` (`def reset_configuration!`, ~line 29) | 0.2.0 | 0.3.0 |
| `render_as:` wrap kwarg + `render_as` setting (value `:text`) | `present_as:` / `present_as` setting (value `:message`) | `lib/axn/ruby_llm/tool_adapter.rb` (`validate_present_as_kwargs!`, `wrap`) | unreleased | 1.0 |

The `render_as` → `present_as` rename (and value `:text` → `:message`) unifies the structured-vs-message render toggle with axn-mcp's `present_as`. Unlike the aliases above, this one **raises** rather than warning — it's a pre-1.0 tool-adapter API that never shipped in a release, so a leftover `render_as:` is a hard error with a pointer (`validate_present_as_kwargs!`), not a silent shim. The `render_as` config setting was hard-removed, so `configure(:ruby_llm) { |c| c.render_as = ... }` raises via axn core's config DSL.

### Removal checklist (1.0)

- Delete the `render_as: NOT_SET` kwarg from `wrap` and the `render_as` guard in `validate_present_as_kwargs!` (`lib/axn/ruby_llm/tool_adapter.rb`); drop the `:text` pointer branch too.
- Remove the "renamed render_as: kwarg" specs from `spec/axn/ruby_llm/tool_adapter_spec.rb`.
- Remove this row and note the removal in `CHANGELOG.md`.

Both aliases were introduced as a compatibility shim when `Axn::RubyLLM` adopted Axn's `Configurable` DSL (which standardizes on `.config` / `.configure` / `reset_config!`). They remain fully functional but emit a `category: :deprecated` warning on use, via the private `_warn_deprecated_alias` helper in `lib/axn/ruby_llm.rb`. `0.2.0` (not `0.1.3`) is recorded as the deprecated-in version because `0.1.3` was cut on the branch but never published — `0.2.0` is the first release that ships these as deprecated-with-warning, so it gets the full one-minor cycle before removal in `0.3.0`.

### Removal checklist (0.3.0)

- Delete `Axn::RubyLLM.configuration`, `Axn::RubyLLM.reset_configuration!`, and the `_warn_deprecated_alias` helper from `lib/axn/ruby_llm.rb`.
- Remove the "deprecated backward-compatible aliases" examples from `spec/axn/ruby_llm/configuration_spec.rb`.
- Remove the rows above and note the removal in `CHANGELOG.md`.
