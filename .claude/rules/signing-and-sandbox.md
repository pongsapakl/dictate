# Signing and Sandbox

## Always Use Apple Development Signing

Ad-hoc signing (`"-"`) does not embed entitlements. The sandbox is not enforced, causing the app to store models at `~/Library/Application Support/Models/` instead of the sandbox container. This causes model re-downloads and confusion.

Use `CODE_SIGN_IDENTITY = "Apple Development"` — entitlements are embedded, sandbox is enforced.

### Known drift — the working tree may override this

As of 2026-07-26 the *committed* `project.pbxproj` has `Apple Development` +
`CODE_SIGN_STYLE = Automatic` (commit `714da79`), but the local working tree carries an
uncommitted change flipping macOS builds to `"-"` + `Manual` with
`DEVELOPMENT_TEAM[sdk=macosx*]`. Every shipped build has therefore been **ad-hoc**.

Verify what you actually shipped, don't trust the committed settings:
```
codesign -dv /Applications/Whisper.app 2>&1 | grep -E "Signature|TeamIdentifier"
```
`Signature=adhoc` / `TeamIdentifier=not set` means the override is active.

Two corrections to the claim above, measured rather than assumed:
- Entitlements **are** present under ad-hoc signing here (`com.apple.security.app-sandbox`
  is embedded) and models do live in the sandbox container. The "models escape to
  `~/Library/Application Support/Models/`" failure has not been observed on this machine.
- The real cost of ad-hoc is elsewhere: an ad-hoc signature is a hash of the binary, so it
  changes on **every build**. The CoreML ANE bundle cache
  (`Containers/soli.whisper.Whisper/Data/Library/Caches/.../com.apple.e5rt.e5bundlecache`,
  ~557MB) was observed rebuilding from scratch at deploy time, which is the "model is
  loading slowly again" symptom. The model files themselves are not re-downloaded.

Note the committed config does **not** build on its own — it pairs `Apple Development`
with `DEVELOPMENT_TEAM = ""` and fails with "requires a development team". Restoring
proper signing means keeping the team line and changing only the identity and style.

Unproven: that the ANE cache is keyed on code signature. The timing matches exactly but
was not isolated. Confirming it needs two consecutive deploys after switching to stable
signing — the first rebuilds the cache regardless.

## All Builds Share the Same Container

Bundle ID `soli.whisper.Whisper` with Apple Development signing → sandbox container at:
```
~/Library/Containers/soli.whisper.Whisper/Data/Library/Application Support/Models/
```

Both Xcode Debug runs and `/Applications/Whisper.app` use this same container. The model downloads once and is shared.

## Do Not Build with CODE_SIGNING_REQUIRED=NO

Command-line builds with signing disabled bypass the sandbox. This was used during early development and caused duplicate model downloads. Always build via Xcode instead.

## Changing Bundle ID Has Consequences

If `soli.whisper.Whisper` is changed, a new sandbox container is created and the model re-downloads. System permissions (microphone, accessibility) also need to be re-granted.
