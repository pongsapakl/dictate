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

## Superseded by the engine swap (kept for history)

Everything below this line described the WhisperKit implementation and no longer applies
to the code. It is retained so the reasoning is not rediscovered if Whisper ever returns.

## AudioStreamTranscriber — Do Not Revert to Chunk+Merge

The original app used a custom `AudioRecorder` + 5-second chunk timer + `mergeTranscriptions()`. This was replaced with WhisperKit's built-in `AudioStreamTranscriber`.

**Why it was replaced:** chunk+merge caused duplicate words, speech cut-off, temperature fallbacks to 1.0, and race conditions. See `docs/transcription-issues.md` for full analysis.

**What AudioStreamTranscriber does:** transcribes the entire growing audio buffer every ~1s using `clipTimestamps` to skip already-confirmed audio. Provides `confirmedSegments` and `unconfirmedSegments` via `stateChangeCallback`. No merging needed.

Do not re-introduce `mergeTranscriptions`, `chunkTimer`, `AudioRecorder`, or `transcriptionQueue`.

## Model Variant — Use Exact Name

Single model, all languages: `openai_whisper-large-v3-v20240930_626MB` (full large-v3).

Decided 2026-07-26, resolving the "Unify on Single Model" investigation. The trigger was
poor accuracy on rare proper nouns and technical jargon — exactly the class of token
turbo's distillation degrades most. Thai was dropped at the same time (rarely used and
never good enough), which removed the only reason for a second variant.

Consequences, deliberate:
- `modelVariant` is a plain constant. `modelVariant(for:)` and `reloadModelIfNeeded()`
  are gone — with one model there is nothing to swap, so changing language no longer
  reloads anything.
- Decode is slower. Full large-v3 has 32 decoder layers vs turbo's 4. Expect the
  post-release wait to grow; if it becomes intolerable the fallback is turbo plus
  `DecodingOptions.promptTokens` biasing rather than reinstating the two-model split.
- "Auto-detect" was removed from the language list and the default is now `en`.
  Auto-detect costs a decode pass and can misfire, and neither helps English accuracy.

Original app used `large-v3`. This fork briefly used turbo (8x faster) and has now
returned to full large-v3 for accuracy.

**The model name must be the exact folder name from `argmaxinc/whisperkit-coreml` on HuggingFace.** A wrong name causes `WhisperKit.download()` to silently fail, leaving `whisperKit = nil` — the app appears to load but never transcribes. This is extremely hard to debug.

Before changing the model name, verify it exists in the repo: `https://huggingface.co/argmaxinc/whisperkit-coreml`

## Token Stripping — Always Required

WhisperKit 0.15.0 includes raw special tokens in `TranscriptionSegment.text` (e.g. `<|startoftranscript|><|en|><|0.00|>`). Always call `stripTokens()` before pasting or displaying any transcription text.

## 300ms Wait After Stop — Do Not Remove

When recording stops, `AudioStreamTranscriber` may still be running one final decode. We wait before reading `lastStreamState`. Removing this causes the last few words of speech to be cut off.

**The wait must come BEFORE `stopStreamTranscription()`, not after.** `stopStreamTranscription()`
tears down the audio engine immediately, so waiting afterwards captures nothing — audio
still in flight when the hotkey is released is lost at the hardware/tap layer and is not
recoverable by any later decode. Waiting first keeps the mic open ~400ms past key release,
which covers CoreAudio tap latency and a slightly early release.

The wait is necessary but not sufficient on its own — see `transcribeTail()` below.

## Tail Flush On Stop — Do Not Remove

`stopStreamTranscription()` does not flush. Up to ~1s of trailing audio is never
submitted to the decoder (`nextBufferSeconds > 1` guard), the decoder itself stops
`windowClipTime` (1.0s) short of the end, and anything captured during the final
in-flight decode is dropped. None of that is recoverable by waiting longer.

`transcribeTail()` in `WhisperApp.swift` re-decodes from `lastConfirmedSegmentEndSeconds`
to the end of `audioProcessor.audioSamples` with `windowClipTime = 0`, and
`finalizeSpeech()` prefers that over the unconfirmed segments. This relies on
`stopRecording()` not clearing `audioSamples` — verified in WhisperKit 0.15.0
`AudioProcessor.swift:1078`. Re-verify on WhisperKit upgrade.

See `docs/transcription-issues.md` Issues 4-6 for the full analysis.

## Stream Tuning Parameters

`AudioStreamTranscriber` is constructed with non-default values:

- `requiredSegmentsForConfirmation: 1` (WhisperKit default 2). At the default, a long
  run-on sentence yields too few segments to ever confirm, so `clipTimestamps` stays
  at 0 and every pass re-decodes the whole utterance. Cost then grows with utterance
  length — this was the "hangs on long sentences" symptom.
- `silenceThreshold: 0.15` (default 0.3). `relativeEnergy` is normalized against the
  running noise floor, so a noisier input device scores identical speech lower. The
  default gated transcribe passes on an external mic. If it still gates, pass
  `useVAD: false` — for push-to-talk dictation, voice-activity gating buys little.

## Live Text Throttle — Do Not Remove

`stateChangeCallback` fires per-token during decoding — dozens of times per second. The `lastLiveText` guard in `handleStreamState` prevents calling `launcherPanel?.updateLiveText()` unless text actually changed. Removing this causes AppKit layout recursion warnings and UI thrashing.
