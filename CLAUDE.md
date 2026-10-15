# CLAUDE.md

## Open Challenges

### Engine swapped to Apple SpeechAnalyzer — 2026-09-06

WhisperKit and the 626MB large-v3 model are gone. See
`.claude/rules/architecture-decisions.md` for the decision, the measured numbers, the
SpeechTranscriber-vs-DictationTranscriber trade-off, and the untested Parakeet fallback.
The old sections on post-release latency, tail decode and model unification are
superseded. Still open after the swap:

- **Hard words.** `Vocabulary.txt` / `Replacements.txt` in Application Support drive
  post-transcription rewrites. DictationTranscriber's custom language model hook is the
  next lever if that is not enough.
- **Is it fast enough in daily use?** Measured 100-300ms release-to-final on the spike;
  the app now records `releaseToFinalMs` per dictation into the corpus JSON, so the
  answer comes from real data.
- **Corpus.** Every dictation can be saved as WAV + JSON (`corpusDirectory` default).
  Purpose: replay real speech against other engines later with `tools/speechbench/`.

### Cursor Lock During Transcription

**What works:**
- Switching to a different app during transcription → paste returns to original app ✓

**What doesn't work:**
- Switching windows within the same app (e.g., iTerm windows) → cannot detect, pastes in wrong window
- iTerm reports all windows with same ID (4444) to Accessibility API, making detection impossible
- AppleScript approach requires authorization that users likely won't grant

**Attempted solutions:**
- CGWindowListCopyWindowInfo - returns helper windows (toolbars), not main windows
- AXFocusedWindow - works for cross-app, but iTerm returns same ID for all windows
- AppleScript for iTerm - "Not authorized to send Apple events"

### Hands-Free Latch

Double-tap the hotkey within 300ms to latch recording on; a single press ends it.
Holding the hotkey still works exactly as before. The cost is that a *short* tap
now waits 300ms before finalising, because it has to see whether a second tap is
coming. Long holds are unaffected.

## Structure

```
Whisper/Whisper/
  WhisperApp.swift          # app delegate: menu, hotkey, dictation flow, paste
  SpeechEngine.swift        # SpeechAnalyzer modules, mic capture, corpus recording
  TextPolish.swift          # Vocabulary.txt / Replacements.txt rewrites, filler stripping
  TranscriptionStore.swift  # transcript files in Application Support
  Diagnostics.swift         # os.Logger + main-thread freeze watchdog
  LauncherPanel.swift       # floating panel, live text, file drop
  ScreenGlow.swift          # screen-edge glow while recording
tools/speechbench/          # replay corpus audio against engines
tools/selftest/             # swiftc self-test for TextPolish and the store
```

## Build and Test

- Xcode ⌘R runs the Debug build (`Whisper Dev.app`); the daily app is a separate Release build.
- `zsh tools/selftest/run.sh` checks the text rules and the transcript store. The Xcode
  project has no test target.

## Diagnostics

- Every dictation step logs to the unified log:
  `log show --last 1h --predicate 'subsystem == "soli.whisper.Whisper"'`
- If the main thread stops responding for 10s, the watchdog logs a fault and writes a
  `sample` of the process to `~/Library/Logs/Whisper/hang-*.txt`.
- Finishing a transcription is capped at 5s; on timeout the partial text is pasted.

## Deploy Reminder

After completing development work that the user wants to use daily, **remind them to deploy**: the Debug build runs from Xcode but the daily app at `/Applications/Whisper.app` is a separate Release build. Personal shortcut: `whisper-ship` (zsh function). See `.claude/CLAUDE.local.md` for details. Don't run it automatically — only after the user has confirmed the change works.

## Rules

### Multi-Agent Environment

- **Multiple agents work on this codebase simultaneously**
- If you encounter a build error or test failure in a file you haven't touched, **do not fix it** - confirm with the user first
- Avoid getting stuck in loops trying to fix issues caused by other agents' in-progress work
- When in doubt about an unexpected error, ask before attempting repairs

### No Comments

- **Never add comments to code** - no exceptions
- Code should be self-explanatory through clear naming and structure

### No Single-Use Variables

- If a variable is only read once, use the expression directly

### Happy Path

- **Focus on the happy path** - write `guard`/`if` conditions for when you do actual work
- **Less code is better**

### Errors Are Never Silent

- Don't add error handling the task doesn't need, and don't hide failures with `try?`
- Where an error can't propagate (UI callbacks, background work), log it with `log.error`

### No Single-Use Functions

- If a function is only used once and is not longer than 10 lines, integrate it inline

### Use Default Parameters

- Use default parameter values instead of checking for `nil`

### Prefer Ternary and `map`/`filter`

- Use the ternary operator for simple conditional assignments
- Use `map`/`filter`/`compactMap` instead of loops when building collections

### Simplicity First

- **Less is more** - always prefer the simplest solution
- **Code should be beautiful** - treat it like an art piece
