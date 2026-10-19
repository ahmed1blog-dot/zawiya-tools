# Zawiya Tools — Mac

Native SwiftUI/AppKit app, macOS 14+, Apple Silicon. Identifier `com.ahmedqa.zawiyatools`.

## Build

```bash
bash vendor/fetch-engines.sh   # once: pinned FFmpeg 9.0.2 + cwebp 1.6.0, SHA-256 verified
bash build.sh                  # dist/Zawiya Tools.app
```

Tests and conversion probe:

```bash
swift test --scratch-path .build-local --build-system native --disable-sandbox
.build-local/release/ZawiyaProbe --verify /tmp/zawiya-verification
```

## Release

1. Bump `VERSION` and `BUILD_NUMBER` in `build.sh` (build number must always increase).
2. `bash release.sh` → `release/Zawiya-Tools-<v>-Mac.zip` + `release/appcast.xml`, signed with the EdDSA key at `~/.zawiya-keys/sparkle-private.key` (keep a backup; losing it means installed apps cannot accept updates).
3. Upload both files to the GitHub release `v<version>` (same release as the Windows build).

Installed apps read `releases/latest/download/appcast.xml` daily, download in the background and install when the user quits.

## Layout

| Path | Role |
|---|---|
| `Sources/ZawiyaCore` | Conversion engine, file safety, announcement validation |
| `Sources/ZawiyaApp` | UI, drag wheel, quick actions, updater, credits, announcement card |
| `Sources/ZawiyaProbe` | Synthetic-file verification and icon generator |
| `vendor/` | Bundled engine fetch script (binaries are not committed) |

See [SECURITY.md](SECURITY.md) for the safety model.
