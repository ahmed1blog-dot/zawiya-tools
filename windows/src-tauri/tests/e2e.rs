//! End-to-end through the real engine layer with a local ffmpeg (skips when none is installed).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use zawiya_tools_lib::engine::{run, Cancel, Engines, Job, Options, Tool};

fn ff(ffmpeg: &Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new(ffmpeg).args(["-hide_banner", "-loglevel", "error", "-y"]).args(args).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    out.stdout
}

fn job(inputs: Vec<PathBuf>, out: &Path, tool: Tool, options: Options) -> Job {
    Job { inputs, output_dir: out.to_path_buf(), tool, options }
}

#[test]
fn real_conversions() {
    let engines = Engines::detect(None);
    let Some(ffmpeg) = engines.ffmpeg.clone() else {
        eprintln!("ffmpeg not found; skipping");
        return;
    };
    let dir = std::env::temp_dir().join(format!("zawiya-e2e-{}", uuid::Uuid::new_v4()));
    let src = dir.join("مصدر"); // Arabic folder name on purpose
    fs::create_dir_all(&src).unwrap();
    let png = src.join("صورة 100%d.png");
    let clear = src.join("clear.png");
    let mp4 = src.join("clip.mp4");
    ff(
        &ffmpeg,
        &["-f", "lavfi", "-i", "testsrc=size=640x360:rate=1", "-frames:v", "1", "-update", "1", png.to_str().unwrap()],
    );
    ff(
        &ffmpeg,
        &[
            "-f",
            "lavfi",
            "-i",
            "color=c=black@0.0:s=8x8,format=rgba",
            "-frames:v",
            "1",
            "-update",
            "1",
            clear.to_str().unwrap(),
        ],
    );
    ff(
        &ffmpeg,
        &[
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x240:rate=25",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440",
            "-t",
            "3",
            "-metadata",
            "title=secret",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            mp4.to_str().unwrap(),
        ],
    );
    let out = dir.join("Zawiya Exports");
    let cancel: Cancel = Default::default();
    let opts = |format: &str| Options { format: format.into(), ..Options::default() };

    // PNG → JPG (name with % kept literal), twice: second run never overwrites.
    let a = run(&job(vec![png.clone()], &out, Tool::Convert, opts("jpg")), &engines, &cancel).unwrap();
    let b = run(&job(vec![png.clone()], &out, Tool::Convert, opts("jpg")), &engines, &cancel).unwrap();
    assert_eq!(a[0].file_name().unwrap(), "صورة 100%d-zawiya.jpg");
    assert_eq!(b[0].file_name().unwrap(), "صورة 100%d-zawiya-2.jpg");
    assert!(fs::read(&a[0]).unwrap().starts_with(&[0xFF, 0xD8, 0xFF]));

    // Transparent PNG → JPG is composited on white.
    let j = run(&job(vec![clear.clone()], &out, Tool::Convert, opts("jpg")), &engines, &cancel).unwrap();
    let rgb = ff(&ffmpeg, &["-i", j[0].to_str().unwrap(), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]);
    assert!(rgb.iter().all(|v| *v > 240), "not white: {:?}", &rgb[..6]);

    // Resize never upscales and keeps aspect ratio.
    let small = run(
        &job(vec![png.clone()], &out, Tool::Resize, Options { max_dimension: 320, ..Options::default() }),
        &engines,
        &cancel,
    )
    .unwrap();
    let big = run(
        &job(vec![png.clone()], &out, Tool::Resize, Options { max_dimension: 4000, ..Options::default() }),
        &engines,
        &cancel,
    )
    .unwrap();
    let size_of = |p: &Path| {
        let raw = ff(&ffmpeg, &["-i", p.to_str().unwrap(), "-f", "rawvideo", "-pix_fmt", "gray", "-"]);
        raw.len()
    };
    assert_eq!(size_of(&small[0]), 320 * 180);
    assert_eq!(size_of(&big[0]), 640 * 360);
    assert_eq!(small[0].extension().unwrap(), "png");

    // Image → PDF and images → PDF.
    let pdf =
        run(&job(vec![png.clone(), clear.clone()], &out, Tool::ImagesToPdf, Options::default()), &engines, &cancel)
            .unwrap();
    assert_eq!(lopdf::Document::load(&pdf[0]).unwrap().get_pages().len(), 2);

    // MP4 → MP3, metadata gone.
    let mp3 = run(&job(vec![mp4.clone()], &out, Tool::Convert, opts("mp3")), &engines, &cancel).unwrap();
    assert_eq!(mp3[0].file_name().unwrap(), "clip-zawiya.mp3");
    let bytes = fs::read(&mp3[0]).unwrap();
    assert!(bytes.len() > 1000 && !bytes.windows(6).any(|w| w == b"secret"));

    // Trim, video frame, extract audio, strip metadata (stream copy).
    let trim = run(
        &job(vec![mp4.clone()], &out, Tool::Trim, Options { start: 0.5, duration: 1.0, ..Options::default() }),
        &engines,
        &cancel,
    )
    .unwrap();
    assert_eq!(trim[0].extension().unwrap(), "mp4");
    let frame = run(
        &job(vec![mp4.clone()], &out, Tool::VideoFrame, Options { start: 1.0, ..Options::default() }),
        &engines,
        &cancel,
    )
    .unwrap();
    assert!(fs::read(&frame[0]).unwrap().starts_with(b"\x89PNG"));
    let audio = run(&job(vec![mp4.clone()], &out, Tool::ExtractAudio, opts("m4a")), &engines, &cancel).unwrap();
    assert_eq!(audio[0].extension().unwrap(), "m4a");
    let clean = run(&job(vec![mp4.clone()], &out, Tool::StripMetadata, Options::default()), &engines, &cancel).unwrap();
    assert!(!fs::read(&clean[0]).unwrap().windows(6).any(|w| w == b"secret"));

    // Every advertised video/audio/image output format really encodes with this ffmpeg.
    let wav = run(&job(vec![mp4.clone()], &out, Tool::Convert, opts("wav")), &engines, &cancel).unwrap();
    for (input, kind) in [
        (&mp4, zawiya_tools_lib::engine::Kind::Video),
        (&wav[0], zawiya_tools_lib::engine::Kind::Audio),
        (&png, zawiya_tools_lib::engine::Kind::Image),
    ] {
        for format in engines.formats(kind) {
            let r = run(&job(vec![input.clone()], &out, Tool::Convert, opts(format)), &engines, &cancel);
            assert!(r.as_ref().is_ok_and(|o| fs::metadata(&o[0]).unwrap().len() > 0), "{kind:?} → {format}: {r:?}");
        }
    }

    // Originals untouched, no scratch left behind.
    assert!(fs::read(&mp4).unwrap().windows(6).any(|w| w == b"secret"));
    assert!(fs::read_dir(&out).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().starts_with(".zawiya-work")));

    // Cancellation before start.
    cancel.store(true, std::sync::atomic::Ordering::SeqCst);
    assert!(run(&job(vec![mp4], &out, Tool::Convert, opts("wav")), &engines, &cancel).is_err());
    fs::remove_dir_all(dir).unwrap();
}
