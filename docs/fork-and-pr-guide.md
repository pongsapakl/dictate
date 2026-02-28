# Fork Notes & PR Considerations

## About This Fork

This is a **personal fork** of [soliblue/dictate](https://github.com/soliblue/dictate), maintained for **local personal use only**.

**Intentions of this fork:**
- Run entirely on a single personal machine
- No TestFlight, no App Store, no distribution to others
- No obligation to keep in sync with upstream
- Changes may diverge significantly from the original

**Not intended:**
- Maintaining Fastlane distribution pipeline
- App Store submission
- Supporting other users' machines or configurations

---

## Key Differences from Original

| Area | Original (`soliblue/dictate`) | This Fork |
|---|---|---|
| Transcription approach | Chunk + merge (5s timer, overlap stitching) | `AudioStreamTranscriber` (real-time streaming) |
| Audio recorder | Custom `AudioRecorder` (AVAudioEngine) | WhisperKit's built-in `audioProcessor` |
| Model | `large-v3` | `openai_whisper-large-v3-v20240930_turbo_632MB` |
| Distribution | Fastlane → TestFlight → App Store | Manual copy to `/Applications/` |
| Code signing | Original author's Apple team (`Q9U8224WWM`) | Local developer's team (auto-selected by Xcode) |
| Signing style | Ad-hoc (`"-"`) for macOS | `Apple Development` (proper sandbox enforcement) |

---

## If You Want to PR Back to Original

Before opening a PR to `soliblue/dictate`, carefully review these files and concerns:

### 🔴 Do NOT include in PR

**`Whisper/Whisper.xcodeproj/project.pbxproj`**
- Contains `DEVELOPMENT_TEAM` — even though we set it to `""` (empty), Xcode may auto-fill your team ID when building
- The `CODE_SIGN_IDENTITY[sdk=macosx*] = "Apple Development"` change IS a good fix (replaces broken ad-hoc signing) and IS worth including
- Carefully diff this file and only include the `CODE_SIGN_IDENTITY` line, not any team ID changes

**`Whisper/fastlane/`**
- This fork has not touched Fastlane but has not tested it either
- Fastlane config references the original team ID `Q9U8224WWM` — do not touch this

**Any personal paths or machine-specific configs**

---

### ✅ Safe to include in PR

**`Whisper/Whisper/WhisperApp.swift`** — the core improvement
- Replaces chunk+merge with `AudioStreamTranscriber`
- Removes ~250 lines of fragile code, replaces with ~50 lines of clean streaming
- Fixes: duplicate words, speech cut-off, race conditions, temperature fallbacks
- Adds: token stripping (`stripTokens`), 300ms finalization wait, live text throttling
- Worth PRing — meaningful improvement to the core transcription quality

**`docs/`** — research and issue documentation
- `whisperkit-research.md` — WhisperKit API findings
- `transcription-issues.md` — bug analysis with root causes
- Useful for anyone working on the project

**`.gitignore`** — improvements
- Added `xcuserdata/` pattern (critical — was missing)
- Added standard Xcode patterns
- All original entries preserved

**`Whisper/Whisper.xcodeproj/xcshareddata/xcschemes/Whisper.xcscheme`**
- Shared Xcode scheme — useful for anyone building the project

---

### ⚠️ Think carefully before including

**Model variant change** (`large-v3` → `openai_whisper-large-v3-v20240930_turbo_632MB`)
- The turbo model is better for most users (faster, less RAM)
- But it changes what users download on first launch (~632MB vs ~3GB)
- The model name must be exact — wrong name causes silent download failure and `whisperKit = nil`
- Worth including with a clear PR description

**`CODE_SIGN_IDENTITY[sdk=macosx*]` in `project.pbxproj`**
- Changing from `"-"` to `"Apple Development"` fixes proper sandbox enforcement
- But it requires the developer to have an Apple Developer account configured
- Original repo may have intentionally used `"-"` for easier contributor setup
- Discuss with the original author before including

---

## Sync Strategy

This fork is currently **ahead of `main`** with changes on `feat/streaming`. If the original repo adds new commits:

```bash
git fetch origin
git log HEAD..origin/main --oneline   # see what's new upstream
git merge origin/main                 # or cherry-pick specific commits
```

Watch for conflicts in:
- `WhisperApp.swift` — significant divergence, manual merge required
- `project.pbxproj` — signing config will conflict, resolve carefully

---

## Branch Structure

```
main          ← synced with soliblue/dictate
feat/streaming ← this fork's primary branch (local use)
```

If merging `feat/streaming` → `main` locally:
```bash
git checkout main
git merge feat/streaming
```

This is safe locally. Do not push `main` to the original remote — it would overwrite the original author's work.
