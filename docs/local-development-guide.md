# Local Development Guide

## How This App is Used Locally

This is a personal macOS menu bar dictation app. It runs entirely on-device using WhisperKit (CoreML). No cloud services involved.

**To run:** Open `Whisper.xcodeproj` in Xcode → ⌘R

**To use daily:** `/Applications/Whisper.app` (copied from Xcode build)

---

## Code Signing & Sandbox — What We Learned the Hard Way

### The Problem We Hit

When building via command line with `CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`, entitlements are **not embedded**. The app runs without sandbox and stores the model at:
```
~/Library/Application Support/Models/
```

When Xcode builds with a real Apple Development certificate, entitlements **are embedded**, sandbox is enforced, and the model is stored at:
```
~/Library/Containers/soli.whisper.Whisper/Data/Library/Application Support/Models/
```

These are two completely different locations. If you copy a command-line-built app to `/Applications/`, it will re-download the model because it looks in the wrong place.

### The Symptom
- App freshly installed to `/Applications/` → starts downloading the model again
- Two copies of the model (~1.2GB wasted)
- Confusing because `ls ~/Library/Application Support/Models/` shows the model exists, but the app can't see it

### The Root Cause
The **sandbox container** is tied to the **bundle identifier** (`soli.whisper.Whisper`). Any app with that bundle ID that is properly signed with sandbox entitlements will use the SAME container. Command-line builds without proper signing bypass this entirely.

### The Fix
Configure Xcode with a real **Apple Development** certificate (not "Sign to Run Locally" / ad-hoc):
- `CODE_SIGN_IDENTITY = "Apple Development"`
- `DEVELOPMENT_TEAM = {your team ID}`

Then ALL builds (Xcode Debug runs AND copies to `/Applications/`) are sandboxed with the same bundle ID → share the same container → share the same model.

### Correct Workflow
```
1. Xcode ⌘R → build & test (Debug, sandboxed)
2. If happy → copy to /Applications/:
   cp -r ~/Library/Developer/Xcode/DerivedData/Whisper-.../Build/Products/Debug/Whisper.app /Applications/
3. Both use ~/Library/Containers/soli.whisper.Whisper/ → same model, no duplication
```

### What NOT to Do
- ❌ Don't build via command line with `CODE_SIGNING_REQUIRED=NO` for production use
- ❌ Don't use `CODE_SIGN_IDENTITY = "-"` (Sign to Run Locally) — entitlements not properly enforced
- ❌ Don't delete the container model thinking you'll save space — the app re-downloads on next launch

---

## Bundle Identifier

Current: `soli.whisper.Whisper` (from the original repo author `soliblue`)

**For personal use:** Leave it as-is. No issues.

**If you want to fork and distribute or publish to App Store:**
- Register a new bundle ID under YOUR Apple Developer account (e.g. `com.yourname.whisper`)
- Update it in Xcode project settings
- Note: changing bundle ID creates a NEW sandbox container → model re-downloads once

---

## Model Storage

Model: `openai_whisper-large-v3-v20240930_turbo_632MB` (~619MB)

Stored at (sandboxed):
```
~/Library/Containers/soli.whisper.Whisper/Data/Library/Application Support/Models/
models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB/
```

Downloaded once from `argmaxinc/whisperkit-coreml` on HuggingFace. Only re-downloads if the folder is missing.

**Old models that accumulated during development (safe to delete if present):**
- `openai_whisper-base` (~140MB)
- `openai_whisper-small` (~464MB)

---

## Known Bugs & Status

| Bug | Status | Notes |
|---|---|---|
| Duplicate words in transcription | ✅ Fixed | Was caused by case-sensitive overlap merge |
| First part of long speech cut off | ✅ Fixed | Merge algorithm was backwards |
| Raw tokens pasted (`<\|en\|>` etc.) | ✅ Fixed | `stripTokens()` regex strips WhisperKit tokens |
| Text cut off at end of recording | ✅ Fixed | 300ms wait after stop for final decode |
| Layout recursion warning | ✅ Fixed | Throttle live text updates to only fire on change |
| Fallbacks to temperature 1.0 | ✅ Improved | AudioStreamTranscriber's shouldStopEarly caps at ~0.6 |
| Short recordings (< 1s) not captured | ⚠️ Known limitation | AudioStreamTranscriber needs ≥1s audio to decode |
| Window switching within same app (e.g. iTerm) | ⚠️ Known limitation | iTerm reports same window ID for all windows |

---

## App Store / Distribution Considerations

If you ever want to distribute this app:

1. **Register bundle ID** under your Apple Developer account
2. **Update signing** — use Distribution certificate instead of Development
3. **Provisioning profile** — create one in Apple Developer portal
4. **Hardened Runtime** — already enabled (`flags=0x10000(runtime)`)
5. **Notarization** — required for non-App-Store distribution outside Xcode
6. **App Review** — if App Store, accessibility + microphone entitlements need justification

The app currently uses `com.apple.security.temporary-exception.apple-events` for hotkey support. This is a temporary exception entitlement that Apple may scrutinize for App Store submission.

---

## Branches

| Branch | Purpose |
|---|---|
| `main` | Stable, synced with original GitHub repo |
| `feat/streaming` | Real-time streaming via AudioStreamTranscriber (current) |

When `feat/streaming` is confirmed stable, merge to `main`. Before merging, consider opening a PR to the original repo at `soliblue/dictate` if the changes are beneficial upstream.
