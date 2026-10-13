# speechbench

Command-line harness for Apple's `SpeechAnalyzer`, used to choose the engine in
September 2026 and to replay saved dictations against either module.

```
swiftc -O -target arm64-apple-macos26.0 -parse-as-library main.swift -o speechbench
./speechbench assets                                  # locales, asset status, formats
./speechbench file  clip.wav transcriber              # batch, prints finals and timing
./speechbench stream clip.wav dictation Word1 Word2   # real-time feed; extra args = contextualStrings
./speechbench mic 10 "USB" transcriber                # live mic; device matched by name substring
```

Modules: `transcriber`, `dictation`, `dictation-plain`, `dictation-long`.
The key number printed is `last buffer -> finalize returned`, the release-to-text latency.
Corpus WAVs written by the app are 16kHz mono and can be passed to `file`/`stream` directly.
