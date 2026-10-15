# Architecture Decisions

These are deliberate decisions that diverge from upstream. Do not revert without strong reason.

## Speech Engine — Apple SpeechAnalyzer, Decided 2026-09-06

WhisperKit is gone. Transcription uses the `Speech` framework's `SpeechAnalyzer`
(macOS 26+), so the deployment target is 26.0 and there is no model download, no
CoreML bundle, and no package dependency. `SpeechEngine.swift` holds the mic capture,
module selection, text post-processing and corpus recording.

**Why:** the post-release wait was 1-2s, almost all of it one Whisper decode over a
30s-padded window. Measured on Apple silicon with the spike in `tools/speechbench/`:
SpeechAnalyzer finalises 100-300ms after the last audio, with equal or better English
accuracy on ordinary words and built-in punctuation and casing.

Two modules are selectable from the Engine menu (`speechModule` default):
- `SpeechTranscriber` (default). Best punctuation and casing. **Ignores
  `AnalysisContext.contextualStrings`**, verified by identical output with and without.
- `DictationTranscriber`. Honours `contextualStrings` and has a custom language model
  hook (`ContentHint.customizedLanguage`). In real-speech tests it ran sentences together,
  emitted stray "." finals and still missed listed words. Kept as the option for when
  custom vocabulary matters more than punctuation. Its live text refreshes faster.

Re-checked 2026-10-13 by replaying 97 real dictations (31 min) from the corpus through
both modules. DictationTranscriber produced 13% fewer words, and nearly all of the gap was
content dropped rather than words changed. It ended 74 sentences against 252, and returned
nothing at all for 4 clips. SpeechTranscriber stays the default; the question is closed
unless Apple ships a new model. Neither output was checked against what was actually said,
but the gap is large enough that doing so would not change the outcome.

Hard words are handled after transcription instead: `Vocabulary.txt` (one term per line,
also passed as contextual strings) auto-generates case-insensitive rewrites that tolerate a
space between camel-case parts ("whisper kit" → "WhisperKit"), and `Replacements.txt`
holds explicit `wrong => Right` rules. Both live in Application Support. Leading fillers
("uh", "um") are stripped.

**Not tested for real, recorded so they are not re-researched:** NVIDIA Parakeet TDT
0.6B v3 via the FluidAudio Swift package (Apache 2.0, CoreML, macOS 14+). Published
numbers: ~2.6% WER LibriSpeech, ~6x faster than Whisper turbo, ~800MB peak RAM, English
plus 25 European languages, no custom vocabulary. It is the fallback if Apple's engine
stalls or its accuracy regresses. Wispr Flow was looked at and is cloud-only; nothing to
borrow on-device.

Consequences:
- Languages are limited to what `SpeechTranscriber` supports; the menu lists ten.
  Changing language or engine re-runs `prepareSpeechAssets()`, which downloads the
  locale's asset if needed and warms the model.
- `releaseGrace` (150ms) keeps the mic open past hotkey release. It replaces the old
  400ms wait; the tail-decode floor is gone because the analyzer sees every buffer.
- Every non-empty dictation is optionally saved as WAV + JSON to the directory in the
  `corpusDirectory` default (unset = off). The app checks the directory exists before
  writing so an unmounted external volume is skipped, not silently recreated. Replay any
  saved WAV against either module with `tools/speechbench/`.

## Reliability — Decided 2026-10-16

Prompted by the app hanging for hours at ~37% CPU with nothing in the log to say why.
The cause was not confirmed; these changes close the likely paths and make the next one visible.

- **Each dictation owns its transcript** (`Dictation` / `Transcript` in `SpeechEngine.swift`).
  Text used to live on the app delegate, so a new dictation started during the previous
  one's finalize wiped or mixed its text. A superseded dictation is now saved to Recent
  Transcriptions instead of being dropped.
- **Finishing is capped at 5s** (`finishTimeout`). `finalizeAndFinishThroughEndOfInput()`
  has no timeout of its own; on expiry the analyzer is cancelled and the partial text is
  pasted. Raised from nothing, not tuned: normal finalize is 100-300ms.
- **Mic capture survives device changes.** On `AVAudioEngineConfigurationChange` the tap is
  reinstalled, but only if the engine stopped or the input format changed; if the input is
  gone, the dictation finishes with what was heard. A 0 Hz / 0-channel input throws instead
  of crashing. The change was seen ~50ms into every recording on the dev machine; the log
  line records the before/after format to show whether a restart was needed.
- **Open: release-to-final latency.** First build with the restart-every-time behaviour:
  median 694ms over 8 dictations (4169, 650, 2010, 700, 775, 689, 429, 315) against a
  345ms median over 207 before. Not yet known whether that was the restart or warm-up
  after launch. Compare `releaseToFinalMs` in the corpus after a day of use.
- **Logging and watchdog** (`Diagnostics.swift`). One `os.Logger` line per step; window
  titles and dictated text are never logged. A background timer pings the main thread and
  writes a `sample` to `~/Library/Logs/Whisper/` after 10s of silence. It uses uptime,
  which pauses during sleep, so waking the Mac does not trigger it.
- **Clipboard is restored after auto-paste**, 1s after Cmd-V, unless something else
  changed it first. The dictated text is marked `org.nspasteboard.TransientType` so
  clipboard managers skip it; Recent Transcriptions keeps it. Without Accessibility the
  text is left on the clipboard as before.
- **Auto-send only presses Enter if the target app is still frontmost.**
- **Not done:** automatic deletion of transcripts or corpus audio (the corpus is kept on
  purpose for engine comparisons), and moving `Vocabulary.txt` / `Transcripts/` into an
  app-specific folder (would need a migration for little gain on a single-user Mac).

## WhisperKit era

The WhisperKit implementation (streaming transcriber, tail flush, model choice, token
stripping) was removed on 2026-09-06. Its decisions are in this file's history at
commit `1041801` if Whisper ever returns.
