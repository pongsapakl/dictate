set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)/selftest"
xcrun swiftc -enable-bare-slash-regex -o "$out" \
  "$root/Whisper/Whisper/TextPolish.swift" \
  "$root/Whisper/Whisper/TranscriptionStore.swift" \
  "$root/tools/selftest/main.swift"
"$out"
