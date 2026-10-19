#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${ZAWIYA_BUILD_DIR:-$PROJECT_ROOT/.build-local}"
OUTPUT_DIR="${ZAWIYA_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
VERSION="0.5.1"
BUILD_NUMBER="6"
SPARKLE_PUBLIC_KEY="xwN4NjzHyuAzOksQlbY8QNT8ki32DNhHO7tuamKtFiQ="
FEED_URL="https://github.com/ahmed1blog-dot/zawiya-tools/releases/latest/download/appcast.xml"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
# Only dependency: Sparkle (binary framework, no build plugins). --disable-sandbox turns off
# SwiftPM's nested subprocess sandbox, which cannot run inside agent filesystem sandboxes.
swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_DIR" \
  --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" \
  --security-path "$BUILD_DIR/security" --manifest-cache local --disable-sandbox --build-system native \
  -c release -Xswiftc -gnone -Xswiftc -module-cache-path -Xswiftc "$BUILD_DIR/module-cache"
APP="$OUTPUT_DIR/Zawiya Tools.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/release/ZawiyaTools" "$APP/Contents/MacOS/ZawiyaTools"
ditto "$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Bundled engines (see vendor/README.md). Without them the app falls back to Homebrew copies.
for engine in ffmpeg cwebp; do
  if [ -x "$PROJECT_ROOT/vendor/bin/$engine" ]; then cp "$PROJECT_ROOT/vendor/bin/$engine" "$APP/Contents/Resources/bin/$engine"
  else printf 'warning: vendor/bin/%s missing; run vendor/fetch-engines.sh\n' "$engine" >&2; fi
done
cp "$PROJECT_ROOT/../LICENSE" "$PROJECT_ROOT/../THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ahmedqa.zawiyatools</string>
<key>CFBundleName</key><string>Zawiya Tools</string>
<key>CFBundleDisplayName</key><string>Zawiya Tools</string>
<key>CFBundleExecutable</key><string>ZawiyaTools</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Ahmed Marwan · ahmedqa.com · GPL-3.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>SUFeedURL</key><string>$FEED_URL</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict></plist>
PLIST
"$BUILD_DIR/release/ZawiyaProbe" --icon "$BUILD_DIR/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Finder may add these two cosmetic attributes after opening the app. They are
# forbidden by codesign; keep security attributes such as quarantine untouched.
/usr/bin/xattr -rd com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -rd com.apple.ResourceFork "$APP" 2>/dev/null || true
# Apple silicon refuses unsigned executables; keep FFmpeg's own Developer ID signature.
/usr/bin/codesign -dv "$APP/Contents/Resources/bin/cwebp" >/dev/null 2>&1 || /usr/bin/codesign --force --sign - "$APP/Contents/Resources/bin/cwebp" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
printf 'Built: %s (v%s)\n' "$APP" "$VERSION"
