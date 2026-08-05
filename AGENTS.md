# AGENTS.md

## Axn actions

Everything in `lib/` (e.g. `Ask`) is an Axn action (`include Axn`). Before writing or modifying
one: `bundle show axn` and read `AGENTS-consuming.md` at that path — the `expects`/`exposes`/`call`
contract, failure surfaces (`fail!`/`fails_on`/unhandled exception, `standalone:`/`join:`), gotchas.

## Deprecations

[DEPRECATIONS.md](DEPRECATIONS.md) tracks deprecated public API.

- Deprecating something: add a row (API, replacement, location, deprecated-in, remove-in) + a
  `CHANGELOG.md` `## [Unreleased]` entry.
- Removing something: delete its row, note the removal in `CHANGELOG.md`.
- Before a release: check for entries whose "Remove in" version has arrived; remove them per their
  checklist.

## Docs

- `internal-docs/` holds internal notes and the specs/plans the `superpowers` skills generate
  (`internal-docs/specs/`, `internal-docs/plans/`) — the location preference `brainstorming` /
  `writing-plans` defer to. Excluded from the packaged gem (`spec.files`).
- `docs/` is reserved for a future user-facing site; don't put internal drafts there.

## Git hooks

`bin/setup` installs a lefthook pre-commit hook (`lefthook.yml`) that runs RuboCop on staged Ruby
files and **blocks** the commit on any offense (lint-only — no autocorrect, since lefthook can't
isolate partially-staged content; fix + re-stage to proceed). `git commit --no-verify` skips it; CI
runs the full `rake` regardless.

## Changes & compatibility

- Tracks [axn](https://github.com/teamshares/axn) closely (`Gemfile`/`Gemfile.lock`). On an axn
  breaking DSL change, migrate call sites in the same PR; assert `result.error`/`result.success`
  with exact `eq`, not `include`.
- CHANGELOG every user-visible change under `## [Unreleased]`.
- `bundle exec rspec && bundle exec rubocop` before done.
