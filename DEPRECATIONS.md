# Deprecations

A living list of deprecated APIs scheduled for removal. When you deprecate something, add a row here with its replacement, where it lives, and the version it will be removed in. When you remove it, delete the row (the CHANGELOG records the removal).

## Scheduled for removal in the next minor version

| Deprecated API | Replacement | Location | Deprecated in | Remove in |
| -------------- | ----------- | -------- | ------------- | --------- |
| `Axn::RubyLLM.configuration` | `Axn::RubyLLM.config` | `lib/axn/ruby_llm.rb` (`def configuration`, ~line 24) | Unreleased (post-0.1.2) | next minor |
| `Axn::RubyLLM.reset_configuration!` | `Axn::RubyLLM.reset_config!` | `lib/axn/ruby_llm.rb` (`def reset_configuration!`, ~line 29) | Unreleased (post-0.1.2) | next minor |

Both aliases were introduced as a compatibility shim when `Axn::RubyLLM` adopted Axn's `Configurable` DSL (which standardizes on `.config` / `.configure` / `reset_config!`). They remain fully functional but emit a `category: :deprecated` warning on use, via the private `_warn_deprecated_alias` helper in `lib/axn/ruby_llm.rb`.

### Removal checklist (next minor)

- Delete `Axn::RubyLLM.configuration`, `Axn::RubyLLM.reset_configuration!`, and the `_warn_deprecated_alias` helper from `lib/axn/ruby_llm.rb`.
- Remove the "deprecated backward-compatible aliases" examples from `spec/axn/ruby_llm/configuration_spec.rb`.
- Remove the rows above and note the removal in `CHANGELOG.md`.
