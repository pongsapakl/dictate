# Transcription Issues

## Issue 1: Duplicate Words

### What
When dictating, the transcribed output sometimes contains duplicated words. For example, saying "hello" produces "hello hello", or saying "one two three" produces "one two three one two three".

### Why
`mergeTranscriptions` used a **case-sensitive** string comparison when detecting overlap between audio chunks. Whisper consistently capitalizes the first word of each new transcription segment. So when the tail of `existing` ends with `"world"` and the head of `new` starts with `"World"`, the comparison fails and falls through to a simple concatenation:

```
existing + " " + new  →  "hello world World foo"
```

### How (proposed fix)
Change comparison to **case-insensitive** by lowercasing both sides before comparing.

---

## Issue 2: First Part of Long Speech Cut Out

### What
When speaking for longer than ~5 seconds, the beginning of the transcription is silently lost in the final pasted output. The user must split speech into short ~10-second segments, which breaks natural speaking flow.

### Why
The `mergeTranscriptions` algorithm was **fundamentally backwards**.

The app records in chunks (every 5 seconds) with 1.5 seconds of overlap audio between chunks. The intent of `mergeTranscriptions` is:

> Find where the **tail** of `existing` overlaps with the **head** of `new`, then return `existing + new[after overlap]`.

But the actual implementation searched for where `new` appeared starting from the **beginning** of `existing`, not the end. When `new` started with the same first word as `existing` (e.g. both started with `"Hello"` — common since Whisper capitalizes segment starts), it matched at position `i=0` and returned **only** `new`, silently discarding all previously accumulated text.

Example:
```
existing = "Hello world how are you"
new      = "Hello doing great"   ← Whisper hallucinated "Hello" as start of new chunk

overlapStart = 0  ← matched at beginning of existing
result = new      ← "Hello doing great"  (lost "world how are you")
```

### Blocker
- Users cannot dictate long sentences naturally
- Must artificially pause and restart every ~10 seconds
- No error or warning is shown — the text is silently lost

### How (proposed fix)
Rewrite the algorithm to correctly find the **longest suffix of `existing`** that matches a **prefix of `new`**, case-insensitively. Then return `existing + new[overlapLen:]`.

```swift
for overlapLen in stride(from: min(existingWords.count, newWords.count, 10), through: 1, by: -1) {
    let existingSuffix = existingWords.suffix(overlapLen).map { $0.lowercased() }
    let newPrefix = newWords.prefix(overlapLen).map { $0.lowercased() }
    if existingSuffix == newPrefix {
        let addition = newWords.dropFirst(overlapLen).joined(separator: " ")
        return addition.isEmpty ? existing : existing + " " + addition
    }
}
return existing + " " + new
```

This also resolves Issue 1 since the comparison is now case-insensitive.

---

## Issue 3: No Audio Feedback — User Has No Signal for Ready / Done

### What
There is no audio cue for:
1. When the model finishes loading and is **ready to record**
2. When transcription is **complete** and text has been pasted to clipboard

### Why this matters (use case)
- The app is a background menu bar tool — users are not looking at it
- Without feedback, users attempt to record while the model is still loading → transcription silently fails
- After recording, users cannot tell when it is safe to paste — if they paste too fast, they get the previous clipboard contents or trigger a double-paste
- This creates a frustrating experience where the user must guess timing

### Blocker
- Users are blocked from knowing when to start speaking
- Users are blocked from knowing when the result is ready to use
- Causes accidental double-pastes and missed transcriptions

### How (proposed fix)
Use `NSSound` to play macOS system sounds at key moments:

| Moment | Sound | Reason |
|--------|-------|--------|
| Model loaded, ready to record | `"Tink"` | Light, non-intrusive — signals the app is ready |
| Transcription pasted to clipboard | `"Pop"` | Brief, satisfying — signals the result is ready to use |

```swift
NSSound(named: .init("Tink"))?.play()  // after whisperKit loads
NSSound(named: .init("Pop"))?.play()   // after copyAndPaste completes
```

---

# Streaming era (AudioStreamTranscriber)

Issues 1–3 above describe the old chunk+merge implementation and are historical.
Issues 4–6 apply to the current `AudioStreamTranscriber` design. Line references are
WhisperKit 0.15.0 (`664e1b5`).

## Issue 4: End of Speech Is Cut Off

### What
The last few words of an utterance are missing from the pasted result. Worse on
long utterances and on slower decodes.

### Why
Three independent causes stack, and none of them is the 300ms wait:

1. **The stream loop never submits the trailing audio.**
   `AudioStreamTranscriber.transcribeCurrentBuffer` (:132) only transcribes once
   at least 1 second of *new* audio has arrived:
   ```swift
   guard nextBufferSeconds > 1 else { ... sleep 100ms; return }
   ```
   So at any instant, up to ~1s of the most recent audio has never been decoded.

2. **The decoder deliberately stops 1 second short of the end.**
   `TranscribeTask` (:122-125) uses `windowClipTime` (default `1.0`,
   `Configurations.swift:176`) to avoid end-of-clip hallucinations:
   ```swift
   let windowPadding = Int(options.windowClipTime * Float(WhisperKit.sampleRate))
   while seek < seekClipEnd - windowPadding {
   ```

3. **`stopStreamTranscription()` does not flush.** It sets `isRecording = false`
   and stops the mic (:89-93). The realtime loop simply exits. Audio captured
   during the final in-flight decode is discarded — unbounded, and it grows with
   decode latency. This is why the symptom worsened when decodes got slower.

The `300ms` sleep in `WhisperApp.stopRecording` only gives an already-running
decode a chance to land. It cannot recover audio that was never fed to the
decoder, so it does not address any of the three causes.

### Fix
`transcribeTail()` in `WhisperApp.swift`: after stopping, re-decode the audio from
`state.lastConfirmedSegmentEndSeconds` to the end of `audioProcessor.audioSamples`
with `windowClipTime = 0`, and use that in place of the unconfirmed segments.
`stopRecording()` does not clear `audioSamples` (`AudioProcessor.swift:1078`), so
the full recording is still available at that point.

## Issue 5: Long Sentences Hang

### What
The longer the sentence, the longer the pause before text appears.

### Why
`transcribeAudioSamples` (:192-194) sets `clipTimestamps = [lastConfirmedSegmentEndSeconds]`,
and `TranscribeTask` starts its seek there. If confirmation never advances, every
pass re-decodes the whole utterance from zero.

Confirmation is gated on segment count (:166):
```swift
if segments.count > requiredSegmentsForConfirmation   // default 2
```
A long, run-on sentence produces 1–2 segments, so nothing is ever confirmed,
`lastConfirmedSegmentEndSeconds` stays at 0, and cost grows with utterance length.
Each pass also re-decodes a full 30s-padded window regardless of actual length.

### Fix
`requiredSegmentsForConfirmation: 1` so the seek point advances and each pass only
decodes new audio.

## Issue 6: Live Text Does Not Stream

### What
Text appears in one block per decode pass rather than flowing.

### Why
`handleStreamState` read only `confirmedSegments` and `unconfirmedSegments`, which
are assigned only at the *end* of a pass (:185, :188). `state.currentText`, which
`onProgressCallback` (:119) updates per token during decoding, was ignored. So the
UI froze for the entire decode — and Issue 5 made that window grow.

### Fix
Prefer `state.currentText` for the trailing portion while a decode is in flight,
falling back to `unconfirmedSegments` when idle. `currentText` also carries the
sentinel `"Waiting for speech..."` (:134, :149), which must be filtered out.

## Why an External Microphone Made This Worse

**Unverified — the mechanism is in the code, but was not measured against a real device.**

VAD gates every transcribe pass (:139-153) on `relativeEnergy` exceeding
`silenceThreshold` (default `0.3`). `relativeEnergy` is not absolute loudness — it
is normalized against the *running noise floor* (`AudioProcessor.swift:905`, `:718-735`):

```
reference = min avg energy over the last ~2s
relative  = (dB(signal) - dB(reference)) / (0 - dB(reference))
```

A higher noise floor shrinks both the numerator and the denominator's range, so
identical speech scores lower:

| noise floor | reference | speech @ RMS 0.05 | relative | > 0.3? |
|---|---|---|---|---|
| 0.001 (quiet room, built-in) | -60 dB | -26 dB | 0.57 | yes |
| 0.01  | -40 dB | -26 dB | 0.35 | barely |
| 0.02  | -34 dB | -26 dB | 0.24 | **no** |

When VAD returns false the loop sleeps 100ms and — critically — does **not** update
`state.lastBufferSize` (:157 runs only after the guard), so the untranscribed
backlog keeps growing. That delays the first decode, inflates every later decode
(Issue 5), and enlarges what is lost at stop (Issue 4).

Mitigation applied: `silenceThreshold: 0.15`. If the mic's floor is high enough
that this is still gated, pass `useVAD: false` — for push-to-talk dictation the
user is deliberately recording, so gating on voice activity buys little.

### How to check
Set `Logging.shared.logLevel = .debug` at startup and watch Console.app. A flood of
`"No voice detected, skipping transcribe"` while actually speaking confirms the
VAD path is the bottleneck. `state.bufferEnergy` in `handleStreamState` carries the
same numbers if in-app logging is preferred.
