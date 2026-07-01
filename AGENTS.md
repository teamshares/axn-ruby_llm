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

## Changes & compatibility

- Tracks [axn](https://github.com/teamshares/axn) closely (`Gemfile`/`Gemfile.lock`). On an axn
  breaking DSL change, migrate call sites in the same PR; assert `result.error`/`result.success`
  with exact `eq`, not `include`.
- CHANGELOG every user-visible change under `## [Unreleased]`.
- `bundle exec rspec && bundle exec rubocop` before done.
