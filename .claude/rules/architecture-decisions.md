# Architecture Decisions

These are deliberate decisions that diverge from upstream. Do not revert without strong reason.

## AudioStreamTranscriber — Do Not Revert to Chunk+Merge

The original app used a custom `AudioRecorder` + 5-second chunk timer + `mergeTranscriptions()`. This was replaced with WhisperKit's built-in `AudioStreamTranscriber`.

**Why it was replaced:** chunk+merge caused duplicate words, speech cut-off, temperature fallbacks to 1.0, and race conditions. See `docs/transcription-issues.md` for full analysis.

**What AudioStreamTranscriber does:** transcribes the entire growing audio buffer every ~1s using `clipTimestamps` to skip already-confirmed audio. Provides `confirmedSegments` and `unconfirmedSegments` via `stateChangeCallback`. No merging needed.

Do not re-introduce `mergeTranscriptions`, `chunkTimer`, `AudioRecorder`, or `transcriptionQueue`.

## Model Variant — Use Exact Name

Current model: `openai_whisper-large-v3-v20240930_turbo_632MB`

Original app used `large-v3`. This fork uses the turbo variant — 8x faster, similar accuracy, fits in 8GB RAM.

**The model name must be the exact folder name from `argmaxinc/whisperkit-coreml` on HuggingFace.** A wrong name causes `WhisperKit.download()` to silently fail, leaving `whisperKit = nil` — the app appears to load but never transcribes. This is extremely hard to debug.

Before changing the model name, verify it exists in the repo: `https://huggingface.co/argmaxinc/whisperkit-coreml`

## Token Stripping — Always Required

WhisperKit 0.15.0 includes raw special tokens in `TranscriptionSegment.text` (e.g. `<|startoftranscript|><|en|><|0.00|>`). Always call `stripTokens()` before pasting or displaying any transcription text.

## 300ms Wait After Stop — Do Not Remove

When recording stops, `AudioStreamTranscriber` may still be running one final decode. We wait 300ms after `stopStreamTranscription()` before reading `lastStreamState`. Removing this causes the last few words of speech to be cut off.

## Live Text Throttle — Do Not Remove

`stateChangeCallback` fires per-token during decoding — dozens of times per second. The `lastLiveText` guard in `handleStreamState` prevents calling `launcherPanel?.updateLiveText()` unless text actually changed. Removing this causes AppKit layout recursion warnings and UI thrashing.
