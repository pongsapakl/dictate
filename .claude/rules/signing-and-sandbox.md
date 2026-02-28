# Signing and Sandbox

## Always Use Apple Development Signing

Ad-hoc signing (`"-"`) does not embed entitlements. The sandbox is not enforced, causing the app to store models at `~/Library/Application Support/Models/` instead of the sandbox container. This causes model re-downloads and confusion.

Use `CODE_SIGN_IDENTITY = "Apple Development"` — entitlements are embedded, sandbox is enforced.

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
