# AGENTS.md

Guidance for agents working in **axn-ruby_llm**. Read before writing code.

## Deprecations

[DEPRECATIONS.md](DEPRECATIONS.md) is the living record of deprecated public API scheduled for
removal. Keep it in sync with the code:

- **Deprecating something?** Add a row to the table: the deprecated API, its replacement, where it
  lives (file + rough line), the version it was deprecated in, and the version it's scheduled for
  removal in. Also note the deprecation in `CHANGELOG.md` under `## [Unreleased]`.
- **Removing something?** Delete its row from `DEPRECATIONS.md` and record the removal in
  `CHANGELOG.md` — the changelog is the historical record once the row is gone.
- **Cutting a release that reaches a "Remove in" version?** Check `DEPRECATIONS.md` first and
  actually remove what's due, per its removal checklist, rather than letting it linger past its
  scheduled version.
- Never let `DEPRECATIONS.md` drift from `lib/` — a stale row (wrong location, already-removed API
  still listed) is worse than no row.

## Changes & compatibility

- This gem tracks [axn](https://github.com/teamshares/axn) closely (see `Gemfile`/`Gemfile.lock`).
  When axn ships a breaking DSL change, migrate call sites in the same PR and verify
  `result.error`/`result.success` strings are unchanged (or deliberately changed) with exact-`eq`
  specs, not loose `include` matchers.
- CHANGELOG every user-visible change under `## [Unreleased]`, promoted to a version heading at
  release time (see `CHANGELOG.md` for the format).
- Run `bundle exec rspec` and `bundle exec rubocop` before calling work done.
