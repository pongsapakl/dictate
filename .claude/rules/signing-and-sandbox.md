# Signing and Sandbox

## Always Use Apple Development Signing

Ad-hoc signing (`"-"`) does not embed entitlements. The sandbox is not enforced, causing the app to store models at `~/Library/Application Support/Models/` instead of the sandbox container. This causes model re-downloads and confusion.

Use `CODE_SIGN_IDENTITY = "Apple Development"` — entitlements are embedded, sandbox is enforced.

### Verify what you shipped, don't trust the committed settings

A local working tree can override the committed signing config, so check the artifact:
```
codesign -dv /Applications/Whisper.app 2>&1 | grep -E "Signature|TeamIdentifier"
```
`Signature=adhoc` / `TeamIdentifier=not set` means an ad-hoc override is active.

Two corrections to the claim above, measured rather than assumed:
- Entitlements **are** embedded under ad-hoc signing, and a sandboxed ad-hoc build does
  keep its models in the container. The "models escape to
  `~/Library/Application Support/Models/`" failure was not reproduced.
- The real cost of ad-hoc is elsewhere: an ad-hoc signature is a hash of the binary, so it
  changes on **every build**. Two things were observed breaking on every deploy as a
  result — the CoreML ANE bundle cache (~550MB) rebuilding from scratch, which presents as
  "the model is loading slowly again", and TCC grants silently ceasing to match. The model
  files themselves are never re-downloaded.

Note that `CODE_SIGN_IDENTITY = "Apple Development"` paired with `DEVELOPMENT_TEAM = ""`
does **not** build — it fails with "requires a development team". A team must be supplied
locally; see `.claude/local-notes/`.

Unproven: that the ANE cache is keyed on code signature specifically. The timing matched
exactly but was never isolated. Confirming it needs two consecutive deploys under stable
signing — the first rebuilds the cache regardless.

## The App Is Not Sandboxed — Do Not Re-enable

`Whisper.entitlements` is intentionally empty. Removed 2026-07-26.

**Why: the App Sandbox blocks synthetic keyboard events into other applications.**
Auto-paste works by posting Cmd+V with `CGEvent.post(tap: .cghidEventTap)` in
`simulatePaste()`. A sandboxed app cannot do this to another process, regardless of
Accessibility permission, and no entitlement grants the capability to third-party apps.

This failure is silent and very easy to misdiagnose:
- `AXIsProcessTrusted()` returns **true**, so the "grant Accessibility" warning never fires
- `CGEvent.post` returns nothing, so there is no error to observe
- The text still reaches the clipboard, so manual Cmd+V works fine

Symptom is "Accessibility is granted but it just doesn't paste." Do not chase TCC,
code signatures, or permission resets — check the entitlements first.

The sandbox costs nothing to drop here: per `fork-context.md` this is a personal
single-machine fork, never App Store, never distributed.

### But keep `com.apple.security.device.audio-input`

**This one is NOT sandbox-scoped.** With `ENABLE_HARDENED_RUNTIME = YES`, the Hardened
Runtime requires it for microphone access independently of the sandbox. Removing it breaks
the microphone entirely:

```
kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input
but it is missing for requesting={soli.whisper.Whisper}
Policy disallows prompt ... access to kTCCServiceMicrophone denied
```

The failure mode is nastier than a plain denial: TCC refuses to even *show* the prompt,
and the Microphone pane in System Settings has no `+` button, so the permission becomes
impossible to grant through the UI. `NSMicrophoneUsageDescription` being present is
necessary but not sufficient — the entitlement gates the prompt itself.

Correct combination for this app: **hardened runtime on, sandbox off, audio-input on.**

The genuinely sandbox-scoped entitlements (`files.user-selected.read-write`,
`network.client`, `temporary-exception.apple-events`) stay removed; they are inert
without the sandbox.

Diagnose microphone problems by streaming TCC decisions, which name the missing
entitlement outright:
```
/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c] "whisper"'
```

## Storage Location Followed the Sandbox

Un-sandboxing changes what `FileManager.urls(for: .applicationSupportDirectory)`
returns, so models and transcripts moved:

```
was:  ~/Library/Containers/soli.whisper.Whisper/Data/Library/Application Support/
now:  ~/Library/Application Support/
```

Existing data was copied across at migration time, so nothing re-downloaded. The old
container is left in place as a backup and can be deleted once the new location is
proven. If a 626MB re-download ever starts unexpectedly, the sandbox state has
probably changed — check the entitlements before assuming the model cache is corrupt.

## Do Not Build with CODE_SIGNING_REQUIRED=NO

Command-line builds with signing disabled bypass the sandbox. This was used during early development and caused duplicate model downloads. Always build via Xcode instead.

## Changing Bundle ID Has Consequences

If `soli.whisper.Whisper` is changed, system permissions (microphone, accessibility)
need to be re-granted. This no longer creates a new sandbox container, since the app
is not sandboxed, but TCC grants are keyed on bundle ID and will reset.
