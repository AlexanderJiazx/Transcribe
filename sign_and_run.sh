#!/bin/bash
# Build, code-sign with a real Apple Development identity, reset the microphone TCC
# state, and launch the app. This is the reliable path to getting the macOS mic prompt:
# a stable Developer signature + a clean TCC state + the usage string/entitlement that are
# already baked into the project. Ad-hoc / unsigned builds will NOT reliably prompt.
set -euo pipefail
cd "$(dirname "$0")"

APP=".xcdd/Build/Products/Debug/AlexTranscribeApp.app"
ENT="App/AlexTranscribeApp.entitlements"
BUNDLE_ID="com.alextranscribe.app"

# Pick the first Apple Development codesigning identity unless SIGN_IDENTITY is set.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "✗ No 'Apple Development' codesigning identity found. Open Xcode ▸ Settings ▸ Accounts and add your Apple ID, then re-run." >&2
  exit 1
fi
echo "› Signing identity: $IDENTITY"

echo "› Building (unsigned, then we sign manually)…"
xcodebuild -project AlexTranscribeApp.xcodeproj -scheme AlexTranscribeApp \
  -configuration Debug -derivedDataPath .xcdd -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

echo "› Signing nested code (inside-out)…"
find "$APP/Contents/MacOS" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force --options runtime --sign "$IDENTITY" "$f"
done
if [ -d "$APP/Contents/Resources/mlx-swift_Cmlx.bundle" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
fi

echo "› Signing the app (hardened runtime + mic entitlement)…"
codesign --force --options runtime --entitlements "$ENT" --sign "$IDENTITY" "$APP"

echo "› Verifying signature…"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" || true

echo "› Clearing any stale microphone permission for ${BUNDLE_ID} ..."
tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "› Launching — the microphone prompt should appear on first launch."
open "$APP"
