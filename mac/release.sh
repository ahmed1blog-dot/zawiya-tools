#!/bin/bash
# Builds the Mac app, zips it, and writes a Sparkle appcast signed with the EdDSA key.
# Output: mac/release/Zawiya-Tools-<version>-Mac.zip and appcast.xml, ready for the GitHub release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
KEY="${SPARKLE_KEY_FILE:-$HOME/.zawiya-keys/sparkle-private.key}"
bash "$ROOT/build.sh"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/dist/Zawiya Tools.app/Contents/Info.plist")
OUT="$ROOT/release"; rm -rf "$OUT"; mkdir -p "$OUT"
ZIP="$OUT/Zawiya-Tools-$VERSION-Mac.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/Zawiya Tools.app" "$ZIP"
"$ROOT/.build-local/artifacts/sparkle/Sparkle/bin/generate_appcast" --ed-key-file "$KEY" \
  --download-url-prefix "https://github.com/ahmed1blog-dot/zawiya-tools/releases/download/v$VERSION/" \
  --link "https://github.com/ahmed1blog-dot/zawiya-tools" -o "$OUT/appcast.xml" "$OUT"
printf 'Release files in %s\n' "$OUT"; ls -la "$OUT"
