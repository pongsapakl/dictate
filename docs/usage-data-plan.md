# Usage Data for Tuning

Design only — not implemented.

## Recommendation

Log **per-session metrics always**, capture **raw audio only on demand**.

Blanket audio recording of every dictation is the expensive, invasive option and it
is not what answers the current questions. The metrics below are a few hundred bytes
per session, contain no speech, and directly identify whether a bad session was a
microphone problem, a VAD gating problem, or a decode-speed problem.

## Always-on: session metrics

One JSON line appended per recording, to `Application Support/metrics.jsonl`:

| field | why it matters |
|---|---|
| `micName`, `micSampleRate` | isolates a specific input device as the regression |
| `energyMin/Median/Max` | tests the VAD normalization hypothesis directly (Issue "Why an External Microphone Made This Worse") |
| `vadSkippedPasses`, `transcribePasses` | how often VAD gated a pass — the smoking gun for hangs |
| `audioSeconds`, `timeToFirstText`, `totalLatency` | perceived-speed data; also settles the open "unify on single model" question with real usage instead of benchmarks |
| `confirmedSegmentCount`, `lastConfirmedEnd` | whether confirmation advanced, or stalled at 0 (Issue 5) |
| `tailSeconds` | how much audio the tail flush had to recover — measures Issue 4 |
| `model`, `language`, `charCount` | segmentation by variant |

No transcript text and no audio in this file, so it is safe to keep indefinitely and
safe to paste into an issue.

## On demand: raw audio

A "Save last recording" menu item that writes the retained `audioSamples` buffer as
16 kHz mono WAV plus the final transcript, only when the user actively hits it after
a bad result. Rationale:

- Storage: 16 kHz mono 16-bit is ~1.9 MB/min. Blanket capture at ~10 min/day is
  ~600 MB/month inside the sandbox container. On-demand keeps it to the handful of
  sessions that actually went wrong, which is also exactly the useful training set.
- Privacy: dictation content is unrestricted personal text. Opt-in per sample beats
  a global toggle that gets forgotten.
- The buffer is already in memory — `stopRecording()` does not clear `audioSamples`
  (`AudioProcessor.swift:1078`), so this needs no new capture path.

Pair each WAV with the transcript and the same metrics record, keyed by session id.

## Fix the timestamp format first

`TranscriptionStore.save` (:24-26) builds its filename with a `DateFormatter` that has
no fixed locale:

```swift
formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
```

Under a 12-hour locale `HH` degrades to `h` with an AM/PM suffix, so files on disk are
actually named:

```
2026-07-26_11-45-14 AM.txt
```

Note ` ` — a narrow no-break space, not a regular space. Consequences: filenames
sort wrong, `1-14-43 PM` and `1-14-43 AM` collide in ordering, and any shell or script
matching on a normal space silently fails to find the file.

Set `formatter.locale = Locale(identifier: "en_US_POSIX")` before pairing anything by
filename, otherwise the audio/transcript/metrics join will be unreliable.
