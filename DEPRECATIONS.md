# Deprecations

A living list of deprecated APIs scheduled for removal. When you deprecate something, add a row here with its replacement, where it lives, and the version it will be removed in. When you remove it, delete the row (the CHANGELOG records the removal).

## Scheduled for removal

| Deprecated API | Replacement | Location | Deprecated in | Remove in |
| -------------- | ----------- | -------- | ------------- | --------- |
| `render_as:` wrap kwarg + `render_as` setting (value `:text`) | `present_as:` / `present_as` setting (value `:message`) | `lib/axn/ruby_llm/tool_adapter.rb` (`validate_present_as_kwargs!`, `wrap`) | unreleased | 1.0 |
| `halt_after:` wrap kwarg + `halt_after` setting | caller-driven loop control (`chat.step` / `chat.complete?`) | removed outright in 0.3.0.rc1 (RubyLLM 2.0 deleted `Tool::Halt`) — no replacement kwarg | 0.3.0.rc1 | already removed |
| `provider_params:` wrap kwarg + `provider_params` setting | `provider_options:` / `provider_options` setting | `lib/axn/ruby_llm/tool_adapter.rb` (`wrap`, `build_tool_class`) | 0.3.0.rc1 | 1.0 |
| `json:` input on `Axn::RubyLLM::Ask` | `schema:` (accepts a Hash, an Axn class via `output_schema`, or a `Schematist::Schema`) | removed outright in 0.3.0.rc1 (no protocol-agnostic JSON-mode field in RubyLLM 2.0) | 0.3.0.rc1 | already removed |

The `render_as` → `present_as` rename (and value `:text` → `:message`) unifies the structured-vs-message render toggle with axn-mcp's `present_as`. This one **raises** rather than warning — it's a pre-1.0 tool-adapter API that never shipped in a release, so a leftover `render_as:` is a hard error with a pointer (`validate_present_as_kwargs!`), not a silent shim. The `render_as` config setting was hard-removed, so `configure(:ruby_llm) { |c| c.render_as = ... }` raises via axn core's config DSL.

`halt_after:` and `json:` are hard removals, not deprecations: RubyLLM 2.0 (PRO-3467) deleted the upstream primitives they depended on (`Tool::Halt`, and any protocol-agnostic JSON-mode request field), so there is no shim to keep working during a deprecation window. `provider_params:` follows the same raising pattern as `render_as:` (see `validate_provider_options_kwargs!`-equivalent guard in `wrap`) rather than a warn-and-alias, since it's still pre-1.0.

### Removal checklist (1.0)

- Delete the `render_as: NOT_SET` kwarg from `wrap` and the `render_as` guard in `validate_present_as_kwargs!` (`lib/axn/ruby_llm/tool_adapter.rb`); drop the `:text` pointer branch too.
- Delete the `provider_params:` guard in `wrap` (`lib/axn/ruby_llm/tool_adapter.rb`).
- Remove the "renamed render_as: kwarg" and "renamed provider_params: kwarg" specs from `spec/axn/ruby_llm/tool_adapter_spec.rb`.
- Remove these rows and note the removal in `CHANGELOG.md`.
