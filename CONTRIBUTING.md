# Contributing to Zawiya Tools

Thanks for helping. This is a small project with one maintainer, so small, focused pull requests get reviewed fastest. Issues and PRs are welcome in English or Arabic.

## Where things live

| Path | What |
|---|---|
| `mac/` | Native macOS app (Swift Package: `ZawiyaCore`, `ZawiyaApp`, `ZawiyaProbe`) |
| `windows/` | Windows app: Tauri 2 shell (`src-tauri/`, Rust) and plain HTML/JS UI (`src/`) |
| `announcements/` | The in-app news card (`banner.json`) |
| `docs/screenshots/` | README images |

## macOS

Requires macOS 14+ on Apple Silicon and Xcode command line tools.

```bash
cd mac
bash vendor/fetch-engines.sh   # once: pinned FFmpeg and cwebp, SHA-256 verified
swift test --scratch-path .build-local --build-system native --disable-sandbox
bash build.sh                  # builds dist/Zawiya Tools.app
```

More in [mac/README.md](mac/README.md).

## Windows

Requires Node 22, Rust stable and the [Tauri 2 prerequisites](https://tauri.app/start/prerequisites/).

```bash
cd windows
npm ci
npx tauri dev                       # run the app
cd src-tauri && cargo test          # run the tests
```

In debug builds the engine looks for `ffmpeg` in `src-tauri/resources/bin` and then on your `PATH`. The end-to-end test (`tests/e2e.rs`) skips itself when no FFmpeg is found, so install one locally if you want it to run.

## Before you open a pull request

- Keep the change focused: one fix or feature per PR.
- Add or update a test when you change conversion, file-safety or announcement logic.
- Never weaken the safety rules in [mac/SECURITY.md](mac/SECURITY.md): no shell execution, no network access from engines, originals are never overwritten.
- Arabic and right-to-left text must keep working. Test with an Arabic file name when your change touches paths or subtitles.
- Do not commit binaries, signing keys or anything from `mac/vendor/bin`.

## Reporting bugs

Open an issue with your OS version, the app version, the tool you used and, if possible, a small sample file. For security problems, follow [mac/SECURITY.md](mac/SECURITY.md) and do not post details publicly.

## License

By contributing you agree that your work is released under **GPL-3.0**, the license of this project.
