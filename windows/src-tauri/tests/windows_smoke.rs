//! Runs only on Windows CI, against the real bundled ffmpeg.exe and pdfium.dll in resources/bin.
#![cfg(windows)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use zawiya_tools_lib::engine::{run, Cancel, Engines, Job, Options, Tool};

fn job(inputs: Vec<PathBuf>, out: &Path, tool: Tool, format: &str) -> Job {
    Job {
        inputs,
        output_dir: out.to_path_buf(),
        tool,
        options: Options { format: format.into(), ..Options::default() },
    }
}

#[test]
fn bundled_engines_pdf_and_ocr() {
    let bin = Path::new(env!("CARGO_MANIFEST_DIR")).join("resources").join("bin");
    let engines = Engines::detect(Some(bin));
    let ffmpeg = engines.ffmpeg.clone().expect("bundled ffmpeg.exe");
    assert!(engines.pdfium_dir.is_some(), "bundled pdfium.dll");
    let dir = std::env::temp_dir().join(format!("zawiya-win-{}", uuid::Uuid::new_v4()));
    let out = dir.join("out");
    fs::create_dir_all(&out).unwrap();
    let png = dir.join("نص.png");
    let status = Command::new(&ffmpeg)
        .args(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=white:s=1200x300", "-frames:v", "1", "-vf"])
        .arg("drawtext=fontfile='C\\:/Windows/Fonts/arial.ttf':text='ZAWIYA TOOLS':fontsize=120:fontcolor=black:x=60:y=90")
        .arg(&png)
        .status()
        .unwrap();
    assert!(status.success());
    let cancel = Cancel::default();
    let ok = |r: Result<Vec<PathBuf>, String>| {
        let files = r.unwrap();
        assert!(!files.is_empty() && files.iter().all(|f| fs::metadata(f).unwrap().len() > 0));
        files
    };
    ok(run(&job(vec![png.clone()], &out, Tool::Convert, "webp"), &engines, &cancel));
    let pdf = ok(run(&job(vec![png.clone()], &out, Tool::ImagesToPdf, "pdf"), &engines, &cancel)).remove(0);
    ok(run(&job(vec![pdf.clone()], &out, Tool::Convert, "png"), &engines, &cancel));
    let languages = zawiya_tools_lib::ocr::languages();
    eprintln!("OCR languages on runner: {languages:?}");
    if !languages.is_empty() {
        for input in [png, pdf] {
            let text = ok(run(&job(vec![input], &out, Tool::ExtractText, "txt"), &engines, &cancel)).remove(0);
            let text = fs::read_to_string(text).unwrap().to_uppercase();
            assert!(text.contains("ZAWIYA"), "OCR text: {text}");
        }
    }
    fs::remove_dir_all(&dir).ok();
}

#[test]
fn wheel_shell_queries() {
    use zawiya_tools_lib::wheel;
    // COM Shell.Application query on the runner (usually no Explorer in front): must not panic.
    let selection = wheel::explorer_selection(false);
    assert!(selection.iter().all(|p| std::path::Path::new(p).is_absolute()), "{selection:?}");
    eprintln!("Explorer selection on runner: {selection:?}; menu installed: {}", wheel::context_menu_installed());
    let exe = r"C:\Program Files\x.png".to_string();
    assert_eq!(wheel::wheel_args(&["z.exe".into(), "--wheel".into(), exe.clone()]), Some(vec![exe]));
    assert!(wheel::to_shortcut(wheel::DEFAULT_HOTKEY).is_some());
}
