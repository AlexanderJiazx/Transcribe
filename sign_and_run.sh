#!/bin/bash
# Build, code-sign, and launch the app. A stable signature keeps the macOS
# microphone + Accessibility TCC grants sticky across runs. Uses an Apple
# Development identity when one exists, otherwise falls back to ad-hoc signing
# (works, but you may need to re-grant permissions after rebuilds since the
# cdhash changes).
set -euo pipefail
cd "$(dirname "$0")"

APP=".xcdd/Build/Products/Debug/Transcribe.app"
ENT="App/AlexTranscribeApp.entitlements"
BUNDLE_ID="com.alexanderjia.app.transcribe"

# Pick the first Apple Development codesigning identity unless SIGN_IDENTITY is
# set; fall back to ad-hoc ("-") when none is installed.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "› No 'Apple Development' identity found — ad-hoc signing."
  IDENTITY="-"
else
  echo "› Signing identity: $IDENTITY"
fi

# Hardened runtime's library validation needs a real Developer ID — with ad-hoc,
# Apple-Development, or self-signed identities it rejects the nested dylibs at launch
# ("different Team IDs").
RUNTIME_OPTS=()
case "$IDENTITY" in
  "Developer ID Application"*) RUNTIME_OPTS=(--options runtime) ;;
esac

echo "› Building (unsigned, then we sign manually)…"
xcodebuild -project Transcribe.xcodeproj -scheme Transcribe \
  -configuration Debug -derivedDataPath .xcdd -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "› Signing nested code (inside-out)…"
find "$APP/Contents/MacOS" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force "${RUNTIME_OPTS[@]}" --sign "$IDENTITY" "$f"
done
if [ -d "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" ]; then
  codesign --force "${RUNTIME_OPTS[@]}" --sign "$IDENTITY" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
fi

echo "› Signing the app (hardened runtime only for Developer ID + mic entitlement)…"
codesign --force "${RUNTIME_OPTS[@]}" --entitlements "$ENT" --sign "$IDENTITY" "$APP"

echo "› Verifying signature…"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier" || true

echo "› Launching (mic + Accessibility prompts appear on first use)."
open "$APP"
