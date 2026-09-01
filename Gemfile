# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# PRO-3282: pin to axn's main branch, which has `Axn::Extensions::Tracing.annotate_span` (PRO-3278)
# ahead of its 0.1.0-alpha.5.2 release. Revert to RubyGems resolution once alpha.5.2 ships.
gem "axn", github: "teamshares/axn", branch: "main"

gem "lefthook", "~> 2.0" # Git-hook manager (pre-commit RuboCop on staged files)
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"
