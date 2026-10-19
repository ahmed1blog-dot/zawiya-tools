#!/bin/bash
# Downloads the pinned conversion engines bundled into the Mac app and verifies their SHA-256.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$DIR/dl" "$DIR/bin"; cd "$DIR/dl"
FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"
FFMPEG_SHA="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-mac-arm64.tar.gz"
WEBP_SHA="bc6bf84cc70f3f8574fba797d1e4a7dea4feebe9fa4be919f202413ea2b3b8f2"
curl -sSfL -o ffmpeg.zip "$FFMPEG_URL"; echo "$FFMPEG_SHA  ffmpeg.zip" | shasum -a 256 -c -
curl -sSfL -o libwebp.tar.gz "$WEBP_URL"; echo "$WEBP_SHA  libwebp.tar.gz" | shasum -a 256 -c -
rm -rf x && mkdir x && unzip -q ffmpeg.zip -d x && tar xzf libwebp.tar.gz -C x
cp x/ffmpeg "$DIR/bin/ffmpeg"; cp x/libwebp-1.6.0-mac-arm64/bin/cwebp "$DIR/bin/cwebp"; rm -rf x
chmod 755 "$DIR/bin/"*; echo "Engines ready in $DIR/bin"
