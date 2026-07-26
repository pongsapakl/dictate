# Fork Context

## What This Fork Is

Fork of `soliblue/dictate` for local use. Not intended for distribution, App Store, or
redistribution.

**This fork:**
- Targets Apple silicon with constrained RAM; model choices assume that budget
- May diverge significantly from upstream

Hardware specifics and operator setup live in `.claude/local-notes/` (untracked).
See `.claude/rules/publishing-safety.md` before adding anything environment-specific
to a tracked file.

**This fork is NOT:**
- A maintained distribution of the original app
- Tested with Fastlane, TestFlight, or App Store pipeline
- Intended to stay fully in sync with upstream

## Relationship to Upstream

The original `soliblue/dictate` has a full App Store/TestFlight distribution pipeline via Fastlane. This fork does not use or maintain that pipeline. Do not run `fastlane` commands — they are untested and may fail due to different signing config.

When upstream adds new features, this fork may selectively pull them in or ignore them depending on relevance to local use.

## How Builds Work Here

No Fastlane. No TestFlight. Just:
- Xcode ⌘R to run and test
- Xcode ⌘B then copy `.app` to `/Applications/` for daily use

See `docs/local-development-guide.md` for full detail.
