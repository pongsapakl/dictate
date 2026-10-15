# Git Workflow Rules

## Remotes

```
origin   → personal fork on GitHub (public — push here)
upstream → soliblue/dictate (original — read-only reference)
```

Never push to `upstream`.

## Branches

- `main` — the app. Work happens here; this is what gets built and used daily.
- Short-lived topic branches off `main` are fine for larger changes.

The fork stopped tracking upstream on 2026-10-16. Upstream has had no commits since
2026-01-15, and this fork replaced its engine (WhisperKit → SpeechAnalyzer), so syncing
or contributing back no longer applies. The one PR sent upstream (realtime streaming) was
closed for that reason.

## Before Committing

- Leave `project.pbxproj` signing changes uncommitted. The local working tree carries the
  development team and the `Whisper Dev` product name; neither belongs in the public repo.
- Follow `publishing-safety.md`. The pre-push hook is a backstop, not the check.
