# WhisperKit Research Notes

## WhisperKit Version

- Package: `argmaxinc/WhisperKit` @ `0.15.0`
- Model repo: `argmaxinc/whisperkit-coreml` on HuggingFace
- Framework: CoreML (NOT MLX — these are incompatible)

---

## Model Variants

Models are stored at `~/Library/Application Support/Models/models/argmaxinc/whisperkit-coreml/{variant}/` for non-sandboxed builds, or inside `~/Library/Containers/{bundle-id}/...` for sandboxed (Xcode Debug) builds.

| Variant | Disk | RAM | Speed | Notes |
|---|---|---|---|---|
| `openai_whisper-tiny` | ~150MB | ~1GB | 10x | Low accuracy |
| `openai_whisper-base` | ~300MB | ~1GB | 7x | Decent |
| `openai_whisper-small` | ~1GB | ~2GB | 4x | Good |
| `openai_whisper-medium` | ~3GB | ~5GB | 2x | Great |
| `openai_whisper-large-v3` | ~6GB | ~10GB | 1x baseline | Best accuracy, too large for 8GB RAM |
| `openai_whisper-large-v3_turbo` | ~600MB | ~2-3GB | 8x | Near large-v3 accuracy |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | ~632MB | ~2-3GB | 8x | ✅ **Currently in use** — latest + quantized |

**Key insight:** `large-v3-turbo` is NOT a valid variant name — the actual name uses underscores: `openai_whisper-large-v3_turbo` or the full quantized name above. Passing an invalid variant causes download to silently fail, leaving `whisperKit = nil`.

---

## WhisperKit.download() Behavior

```swift
WhisperKit.download(variant: "openai_whisper-large-v3-v20240930_turbo_632MB", downloadBase: modelFolder)
```

- Searches HuggingFace repo for `*{variant}/*` glob pattern
- If multiple matches → prepends `*openai*` to disambiguate
- Returns URL to the specific model folder
- The model contains: `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, `TextDecoder.mlmodelc`, `TextDecoderContextPrefill.mlmodelc`, `config.json`, `generation_config.json`

---

## WhisperKit Init

```swift
// Convenience init - takes modelFolder as String path
whisperKit = try await WhisperKit(modelFolder: modelPath.path)
```

- When `modelFolder` is provided, automatically calls `loadModels()` which compiles CoreML models
- First load can take 30-60 seconds (CoreML compilation) — subsequent loads are faster due to caching
- ALL components become public properties after init

### Public Properties Available After Init

```swift
whisperKit.audioProcessor   // any AudioProcessing
whisperKit.featureExtractor // any FeatureExtracting
whisperKit.audioEncoder     // any AudioEncoding
whisperKit.textDecoder      // any TextDecoding
whisperKit.segmentSeeker    // any SegmentSeeking
whisperKit.tokenizer        // WhisperTokenizer? (optional)
```

---

## DecodingOptions

```swift
public struct DecodingOptions {
    var language: String?                      // nil = auto-detect
    var usePrefillPrompt: Bool                 // default: true
    var usePrefillCache: Bool                  // default: true
    var temperature: Float                     // default: 0.0
    var temperatureIncrementOnFallback: Float  // default: 0.2
    var temperatureFallbackCount: Int          // default: 5 ← causes quality degradation
    var compressionRatioThreshold: Float?      // default: 2.4
    var logProbThreshold: Float?               // default: -1.0
    var firstTokenLogProbThreshold: Float?     // default: -1.5
    var noSpeechThreshold: Float?              // default: 0.6
    var clipTimestamps: [Float]                // default: [] ← KEY for streaming
}
```

**`clipTimestamps`**: Tells Whisper to skip audio before this timestamp (seconds). Used by `AudioStreamTranscriber` to avoid re-processing already-confirmed audio. This is the core mechanism for efficient real-time streaming.

---

## TranscriptionCallback

```swift
public typealias TranscriptionCallback = ((TranscriptionProgress) -> Bool?)?

public struct TranscriptionProgress {
    var text: String           // current accumulated text
    var tokens: [Int]          // predicted token IDs
    var temperature: Float?
    var avgLogprob: Float?     // quality indicator
    var compressionRatio: Float?
    var windowId: Int
    var timings: TranscriptionTimings
}
```

- Called **per token** during decoding (very frequent)
- Return `nil` or `true` = continue, `false` = stop early
- Runs on a detached background task (non-blocking)

---

## AudioStreamTranscriber — The Right Solution

WhisperKit ships `AudioStreamTranscriber`, a built-in real-time streaming class.

```swift
public actor AudioStreamTranscriber {
    struct State {
        var isRecording: Bool
        var currentText: String              // hypothesis text (in-flight)
        var confirmedSegments: [TranscriptionSegment]   // stable confirmed text
        var unconfirmedSegments: [TranscriptionSegment] // recent, may change
        var unconfirmedText: [String]
        var lastConfirmedSegmentEndSeconds: Float
        var bufferEnergy: [Float]
        var currentFallbacks: Int
        var lastBufferSize: Int
    }
}

public typealias AudioStreamTranscriberCallback = (State, State) -> Void
// Called with (oldState, newState) on every state change
```

### Init

```swift
AudioStreamTranscriber(
    audioEncoder: wk.audioEncoder,
    featureExtractor: wk.featureExtractor,
    segmentSeeker: wk.segmentSeeker,
    textDecoder: wk.textDecoder,
    tokenizer: wk.tokenizer!,       // ← must unwrap, it's optional
    audioProcessor: wk.audioProcessor,
    decodingOptions: options,
    requiredSegmentsForConfirmation: 2,  // default
    silenceThreshold: 0.3,              // default (VAD)
    useVAD: true,                        // default — skips silence
    stateChangeCallback: { oldState, newState in ... }
)
```

### Usage

```swift
// Start — this is async and runs until stopped
try await transcriber.startStreamTranscription()

// Stop — sync, just sets flag + stops audio processor
transcriber.stopStreamTranscription()
```

### How It Works Internally

1. Starts mic recording via `audioProcessor.startRecordingLive`
2. Loops: every time >= 1 second of new audio arrives, transcribes the **entire growing buffer**
3. Uses `clipTimestamps = [lastConfirmedSegmentEndSeconds]` to skip already-processed audio
4. Segments confirmed after `requiredSegmentsForConfirmation` more segments arrive (default 2)
5. `stateChangeCallback` fires on every state change with old + new state

### What Is / Is Not Possible

| | ✅ Possible | ❌ Not Possible |
|---|---|---|
| Real-time display | Yes — via stateChangeCallback | |
| Confirmed vs hypothesis | Yes — confirmedSegments / unconfirmedSegments | |
| Feed growing buffer | Yes — internally handles it | |
| True token-level streaming | No — token callback exists but model still decodes in windows | |
| "Eager" mode flag | No — not in this version (0.15.0) | |
| maxTokensPerLoop config | No — not exposed | |
| Sub-0.5s latency | No — minimum 1s of new audio per update | |

---

## Current App Architecture (Before Streaming)

### The Chunk+Merge Approach (current)

```
Recording starts
    ↓
chunkTimer fires every 5s
    ↓
transcribeCurrentChunk() → transcribes from (lastChunkEnd - 1.5s overlap) to NOW
    ↓
mergeTranscriptions(existing, new) → stitches chunks together
    ↓
Recording stops → final transcription of remaining audio
    ↓
merge again → paste
```

### Known Bugs in Current Approach

**Bug 1 — Duplicate words (FIXED in commit 5fbc4e0)**
- Root cause: merge was case-sensitive; Whisper capitalizes first word of each segment
- `"world"` ≠ `"World"` → fell through to `existing + " " + new` → duplicate
- Fix: case-insensitive comparison (`lowercased()` before comparing)

**Bug 2 — First part of long speech cut out (FIXED in commit 5fbc4e0)**
- Root cause: merge algorithm was backwards — searched for new text at BEGINNING of existing instead of matching TAIL of existing to HEAD of new
- If new chunk started with same word as beginning of existing → `overlapStart=0` → returned only `new`, discarding everything before
- Fix: rewritten to match suffix-of-existing against prefix-of-new

**Bug 3 — Fallback temperature degradation (UNFIXED)**
- Symptom: short audio clips (< 3s) trigger 6 temperature fallbacks up to temp=1.0
- At temp=1.0, Whisper produces random/garbage output ("log" → "love")
- Caused by: final chunk transcription on short remaining audio after last 5s chunk
- Root cause: the chunk+merge approach inherently produces short, low-quality final chunks
- The streaming approach avoids this by always transcribing the full growing buffer

**Bug 4 — Race condition (UNFIXED)**
- If chunk transcription is still running when user stops, it may update `accumulatedTranscription` after the final transcription reads it
- `recordingSessionId` guard partially mitigates this but doesn't fully prevent it

---

## Sandbox vs Non-Sandbox

| Build | Model Path | Notes |
|---|---|---|
| Xcode Debug | `~/Library/Containers/{bundle-id}/Data/Library/Application Support/Models/...` | Sandboxed |
| Command-line Release (`CODE_SIGNING_REQUIRED=NO`) | `~/Library/Application Support/Models/...` | Not sandboxed |

Models downloaded by one build are NOT accessible to the other. Each must download separately.

---

## What Should / Should Not Be Done

### ✅ Should Do
- Use `AudioStreamTranscriber` for real-time transcription — it's the right native API
- Extract all components from `whisperKit` instance (they're all public)
- Use `stateChangeCallback` to drive live UI updates
- On recording stop, use `confirmedSegments + unconfirmedSegments` for final text — no merge needed
- Keep `logFocusInfo()` / `restoreWindow()` / `copyAndPaste()` — these are unrelated to transcription

### ❌ Should Not Do
- Do not use `mergeTranscriptions()` — the streaming approach makes it obsolete
- Do not feed partial audio slices to `whisperKit.transcribe()` manually — use `AudioStreamTranscriber`
- Do not try to use MLX models (`mlx-community/...`) — WhisperKit is CoreML only
- Do not pass invalid variant names to `WhisperKit.download()` — fails silently, `whisperKit` stays nil
- Do not transcribe chunks < 1 second — Whisper degrades badly on very short audio
- Do not implement custom rolling buffer logic — `AudioStreamTranscriber` already does this correctly
- Do not keep the custom `AudioRecorder` class — `whisperKit.audioProcessor` replaces it entirely

### ⚠️ Caution
- `whisperKit.tokenizer` is `Optional` — must unwrap before passing to `AudioStreamTranscriber`
- `AudioStreamTranscriber.startStreamTranscription()` is async and runs until stopped — must be called in a `Task`
- `AudioStreamTranscriber.stopStreamTranscription()` is sync but the internal loop may still be running one more iteration — capture `lastStreamState` before calling stop
- `stateChangeCallback` fires frequently (per state change) — keep it lightweight, dispatch UI updates to MainActor
- Segments are only "confirmed" after `requiredSegmentsForConfirmation` more segments arrive — for short recordings, all segments may remain "unconfirmed" — always use both confirmed + unconfirmed for final text
