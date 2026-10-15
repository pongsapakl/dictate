# Dictate

Voice-to-text dictation for macOS. Hold Right Option to record, release to transcribe and paste.
Double-tap to latch recording on for hands-free use.

Menu bar app built on Apple's on-device `SpeechAnalyzer` (macOS 26+). No model download, no network.

**Run:** open `Whisper/Whisper.xcodeproj` in Xcode → Run (⌘R). Grant Microphone and Accessibility.

**Custom words:** Engine → Custom Words… opens `Vocabulary.txt`; explicit rewrites go in
`Replacements.txt` next to it (`wrong phrase => Right Phrase`).

**Logs:** `log show --last 1h --predicate 'subsystem == "soli.whisper.Whisper"'`

Forked from [soliblue/dictate](https://github.com/soliblue/dictate), which has no license file.
