# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# PRO-2996: pin to axn's main branch, which has `Axn::Tools::AdapterSerialization` (PRO-2996) and
# `Axn::Extensions::Tracing.annotate_span` (PRO-3278) ahead of its 0.1.0-alpha.6 release. Revert to
# RubyGems resolution -- and raise the gemspec floor to ">= 0.1.0-alpha.6" -- once alpha.6 ships.
gem "axn", github: "teamshares/axn", branch: "main"

gem "lefthook", "~> 2.0" # Git-hook manager (pre-commit RuboCop on staged files)
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"
