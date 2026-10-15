# Fork Context

## What This Fork Is

Fork of `soliblue/dictate`, developed independently for personal use on one Mac. Not
distributed, not on the App Store. Since 2026-10-16 it no longer tracks or contributes to
upstream; see `git-workflow.md`.

Hardware specifics and operator setup live in `.claude/local-notes/` (untracked).
See `publishing-safety.md` before adding anything environment-specific to a tracked file.

## License

Upstream has no license file (GitHub reports none). With no license, the original code is
all rights reserved: GitHub's Terms of Service let others view and fork a public repo
on GitHub, nothing more. Consequences for this fork:

- Keep it as a GitHub fork. Do not re-publish it as a standalone repo.
- Do not distribute builds (App Store, downloads) without the original author's permission.
- Personal use of a modified build on one's own machine is the intended scope.

If distribution ever matters, ask the original author to add a license first.

## How Builds Work Here

- Xcode ⌘R runs the Debug build (`Whisper Dev.app`).
- The daily app is a Release build copied to `/Applications/`.
- No Fastlane or TestFlight; the upstream pipeline was removed.
