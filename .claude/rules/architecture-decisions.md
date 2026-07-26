# Architecture Decisions

These are deliberate decisions that diverge from upstream. Do not revert without strong reason.

## AudioStreamTranscriber — Do Not Revert to Chunk+Merge

The original app used a custom `AudioRecorder` + 5-second chunk timer + `mergeTranscriptions()`. This was replaced with WhisperKit's built-in `AudioStreamTranscriber`.

**Why it was replaced:** chunk+merge caused duplicate words, speech cut-off, temperature fallbacks to 1.0, and race conditions. See `docs/transcription-issues.md` for full analysis.

**What AudioStreamTranscriber does:** transcribes the entire growing audio buffer every ~1s using `clipTimestamps` to skip already-confirmed audio. Provides `confirmedSegments` and `unconfirmedSegments` via `stateChangeCallback`. No merging needed.

Do not re-introduce `mergeTranscriptions`, `chunkTimer`, `AudioRecorder`, or `transcriptionQueue`.

## Model Variant — Use Exact Name

Default model: `openai_whisper-large-v3-v20240930_turbo_632MB`
Thai model: `openai_whisper-large-v3-v20240930_626MB` (full large-v3, not turbo — turbo's distillation disproportionately degrades Thai per OpenAI)

`modelVariant(for:)` in `WhisperApp.swift` picks the variant by `selectedLanguage`. Changing language reloads the model via `reloadModelIfNeeded()`. The full large-v3 is slower per decode but more accurate on Thai; turbo stays the default for English and everything else.

Original app used `large-v3`. This fork uses the turbo variant — 8x faster, similar accuracy, fits in 8GB RAM.

**The model name must be the exact folder name from `argmaxinc/whisperkit-coreml` on HuggingFace.** A wrong name causes `WhisperKit.download()` to silently fail, leaving `whisperKit = nil` — the app appears to load but never transcribes. This is extremely hard to debug.

Before changing the model name, verify it exists in the repo: `https://huggingface.co/argmaxinc/whisperkit-coreml`

## Token Stripping — Always Required

WhisperKit 0.15.0 includes raw special tokens in `TranscriptionSegment.text` (e.g. `<|startoftranscript|><|en|><|0.00|>`). Always call `stripTokens()` before pasting or displaying any transcription text.

## 300ms Wait After Stop — Do Not Remove

When recording stops, `AudioStreamTranscriber` may still be running one final decode. We wait 300ms after `stopStreamTranscription()` before reading `lastStreamState`. Removing this causes the last few words of speech to be cut off.

The 300ms wait is necessary but was never sufficient — see `transcribeTail()` below.

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
