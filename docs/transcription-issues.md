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
