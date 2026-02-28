# Git Workflow Rules

## Remote Setup

```
origin   → pongsapakl/dictate (personal fork — push here)
upstream → soliblue/dictate   (original — pull updates from here)
```

Never push to `upstream`. You don't have write access and it would overwrite the original author's work.

## Branch Rules

- `main` — always mirrors `upstream/main` exactly. Never commit personal work here.
- `dev/pongsapakl` — personal working branch. Has everything: fixes, docs, personal configs, streaming refactor. This is what gets built and used daily.
- Feature/fix branches — created from `main` when preparing a clean PR.

## Staying in Sync with Upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main      # fast-forward only
git push origin main         # keep fork's main in sync
git checkout dev/pongsapakl
git rebase main              # keep personal work on top of latest upstream
```

Or use GitHub's "Sync fork" button for main, then rebase locally.

## Contributing Back (PR to upstream)

Use cherry-pick, not a direct PR from `dev/pongsapakl`. That branch has personal configs mixed in.

```bash
git checkout -b pr/description main
git cherry-pick <commit> <commit>   # pick only relevant commits
git push origin pr/description
# open PR: pongsapakl/dictate:pr/description → soliblue/dictate:main
```

### Safe to include in PR
- `Whisper/Whisper/WhisperApp.swift` — streaming refactor, token stripping, audio feedback
- `.gitignore` — added xcuserdata/ and standard Xcode patterns
- `docs/whisperkit-research.md`, `docs/transcription-issues.md`
- `Whisper/Whisper.xcodeproj/xcshareddata/` — shared scheme

### Do NOT include in PR
- `project.pbxproj` — contains personal team ID context, signing changes need careful review
- `docs/local-development-guide.md` — references personal machine setup
- `docs/fork-and-pr-guide.md` — fork-specific, not relevant upstream
- `CLAUDE.md` — keep original author's version
- `.claude/` directory — personal workflow tooling
- `Whisper/fastlane/` — not tested in this fork, do not touch

### Before submitting any PR
- Revert `DEVELOPMENT_TEAM` in `project.pbxproj` to `""` or original value
- Double-check `git diff main` to ensure no personal info leaked
- The `CODE_SIGN_IDENTITY[sdk=macosx*] = "Apple Development"` change IS worth including (fixes broken ad-hoc signing)
