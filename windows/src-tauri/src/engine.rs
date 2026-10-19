//! Conversion core: models, validation, ffmpeg arguments, subtitles, ZIP and safe publishing.
//! Ported from the Mac `ZawiyaCore` (Converter.swift / Models.swift / ProcessRunner.swift).

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub type Cancel = Arc<AtomicBool>;
pub const MAX_INPUTS: usize = 2000;
pub const MAX_PDF_PAGES: usize = 2000;
const PROCESS_TIMEOUT: Duration = Duration::from_secs(1200);
const MEDIA_DEMUXERS: &str = "mov,matroska,webm,avi,asf,mp3,wav,flac,ogg,aiff,aac";

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Image,
    Video,
    Audio,
    Pdf,
    Subtitle,
    Archive,
    Document,
    Folder,
    Unknown,
}

pub fn ext_of(path: &Path) -> String {
    path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase()
}

impl Kind {
    pub fn detect(path: &Path) -> Kind {
        if path.is_dir() {
            return Kind::Folder;
        }
        match ext_of(path).as_str() {
            "pdf" => Kind::Pdf,
            "srt" | "vtt" => Kind::Subtitle,
            "zip" | "tar" | "gz" | "tgz" | "rar" | "7z" => Kind::Archive,
            "doc" | "docx" | "pages" | "ppt" | "pptx" | "xls" | "xlsx" | "ods" | "csv" | "tsv" | "txt" | "md"
            | "rtf" | "epub" | "html" => Kind::Document,
            "jpg" | "jpeg" | "png" | "heic" | "heif" | "tiff" | "tif" | "bmp" | "gif" | "webp" | "avif" => Kind::Image,
            "mp3" | "m4a" | "wav" | "flac" | "ogg" | "opus" | "aiff" | "aif" | "wma" | "aac" => Kind::Audio,
            "mp4" | "mov" | "mkv" | "webm" | "avi" | "wmv" | "m4v" => Kind::Video,
            _ => Kind::Unknown,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Tool {
    Convert,
    Compress,
    Resize,
    StripMetadata,
    ExtractAudio,
    Trim,
    VideoFrame,
    ImagesToPdf,
    MergePdf,
    SplitPdf,
    ExtractText,
    Zip,
}

impl Tool {
    pub const ALL: [Tool; 12] = [
        Tool::Convert,
        Tool::Compress,
        Tool::Resize,
        Tool::StripMetadata,
        Tool::ExtractAudio,
        Tool::Trim,
        Tool::VideoFrame,
        Tool::ImagesToPdf,
        Tool::MergePdf,
        Tool::SplitPdf,
        Tool::ExtractText,
        Tool::Zip,
    ];
    pub fn accepts(self, kind: Kind) -> bool {
        use Kind::*;
        match self {
            Tool::Convert => matches!(kind, Image | Video | Audio | Pdf | Subtitle),
            Tool::Compress | Tool::StripMetadata => matches!(kind, Image | Video | Audio),
            Tool::Resize | Tool::ImagesToPdf => kind == Image,
            Tool::Trim => matches!(kind, Video | Audio),
            Tool::VideoFrame | Tool::ExtractAudio => kind == Video,
            Tool::MergePdf | Tool::SplitPdf => kind == Pdf,
            Tool::ExtractText => matches!(kind, Image | Pdf),
            Tool::Zip => true,
        }
    }
    pub fn grouped(self) -> bool {
        matches!(self, Tool::ImagesToPdf | Tool::MergePdf | Tool::Zip)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Options {
    pub format: String,
    pub quality: u32,
    pub max_dimension: u32,
    pub start: f64,
    pub duration: f64,
}

impl Default for Options {
    fn default() -> Self {
        Options { format: "png".into(), quality: 80, max_dimension: 1920, start: 0.0, duration: 10.0 }
    }
}

impl Options {
    pub fn validate(&self) -> Result<(), String> {
        let ok = (1..=100).contains(&self.quality)
            && (16..=16000).contains(&self.max_dimension)
            && self.start.is_finite()
            && self.duration.is_finite()
            && (0.0..=604_800.0).contains(&self.start)
            && self.duration > 0.0
            && self.duration <= 604_800.0
            && (1..=5).contains(&self.format.len())
            && self.format.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
        if ok {
            Ok(())
        } else {
            Err(err_invalid_options())
        }
    }
}

pub fn err_invalid_options() -> String {
    "إعدادات غير صالحة / Invalid options.".into()
}
fn err_unsupported(s: &str) -> String {
    format!("مسار غير مدعوم / Unsupported: {s}")
}
fn err_invalid_file(s: &str) -> String {
    format!("تعذر قراءة الملف / Cannot read: {s}")
}
fn err_missing(s: &str) -> String {
    format!("المحرك غير متوفر / Engine unavailable: {s}")
}
pub fn err_cancelled() -> String {
    "أُلغيت المهمة / Cancelled.".into()
}
fn io_err(e: impl std::fmt::Display) -> String {
    format!("خطأ في الملفات / File error: {e}")
}

pub fn check(cancel: &Cancel) -> Result<(), String> {
    if cancel.load(Ordering::SeqCst) {
        Err(err_cancelled())
    } else {
        Ok(())
    }
}

/// Engines resolved once at startup. `encoders` comes from `ffmpeg -encoders`.
#[derive(Clone, Debug, Default)]
pub struct Engines {
    pub ffmpeg: Option<PathBuf>,
    pub encoders: HashSet<String>,
    pub pdfium_dir: Option<PathBuf>,
}

impl Engines {
    pub fn detect(resource_bin: Option<PathBuf>) -> Engines {
        let exe = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
        let mut candidates: Vec<PathBuf> = resource_bin.iter().map(|d| d.join(exe)).collect();
        if !cfg!(windows) {
            candidates.push("/opt/homebrew/bin/ffmpeg".into());
            candidates.push("/usr/local/bin/ffmpeg".into());
        }
        if cfg!(debug_assertions) {
            // Dev fallback only; release builds never search PATH.
            if let Some(path) = std::env::var_os("PATH") {
                candidates.extend(std::env::split_paths(&path).map(|d| d.join(exe)));
            }
        }
        let ffmpeg = candidates.into_iter().find(|p| p.is_file());
        let encoders = ffmpeg.as_deref().map(probe_encoders).unwrap_or_default();
        let pdfium_dir = resource_bin.filter(|d| {
            d.join(if cfg!(windows) {
                "pdfium.dll"
            } else if cfg!(target_os = "macos") {
                "libpdfium.dylib"
            } else {
                "libpdfium.so"
            })
            .is_file()
        });
        Engines { ffmpeg, encoders, pdfium_dir }
    }

    pub fn formats(&self, kind: Kind) -> Vec<&'static str> {
        let has = |e: &str| self.encoders.contains(e);
        let keep = |f: &&str| match *f {
            "webp" => has("libwebp"),
            "webm" => has("libsvtav1") && has("libopus"),
            "mp3" => has("libmp3lame"),
            "ogg" | "opus" => has("libopus"),
            _ => true,
        };
        if self.ffmpeg.is_none() {
            return match kind {
                Kind::Pdf => vec!["txt", "md"],
                Kind::Subtitle => vec!["srt", "vtt", "txt"],
                _ => vec![],
            };
        }
        let all: &[&'static str] = match kind {
            Kind::Image => &["jpg", "png", "webp", "tiff", "bmp", "pdf"],
            Kind::Video => &["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav"],
            Kind::Audio => &["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
            Kind::Pdf => &["png", "jpg", "txt", "md"],
            Kind::Subtitle => &["srt", "vtt", "txt"],
            _ => &[],
        };
        all.iter().copied().filter(keep).collect()
    }

    fn ffmpeg(&self) -> Result<&Path, String> {
        self.ffmpeg.as_deref().ok_or_else(|| err_missing("FFmpeg"))
    }
}

fn probe_encoders(ffmpeg: &Path) -> HashSet<String> {
    let mut cmd = Command::new(ffmpeg);
    cmd.args(["-hide_banner", "-encoders"]).stdin(Stdio::null()).stderr(Stdio::null());
    no_window(&mut cmd);
    let Ok(out) = cmd.output() else { return HashSet::new() };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_whitespace().nth(1).map(str::to_string))
        .collect()
}

#[cfg(windows)]
fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
}
#[cfg(not(windows))]
fn no_window(_: &mut Command) {}

/// Runs an engine with argument vectors only (no shell). Cancellation and the timeout kill the
/// child; only the last few KB of stderr are kept.
pub fn run_process(exe: &Path, args: &[String], cwd: &Path, cancel: &Cancel) -> Result<(), String> {
    check(cancel)?;
    let mut cmd = Command::new(exe);
    cmd.args(args).current_dir(cwd).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    no_window(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| err_missing(&format!("{} ({e})", exe.display())))?;
    let mut stderr = child.stderr.take().expect("piped stderr");
    let reader = std::thread::spawn(move || {
        let (mut tail, mut buf) = (Vec::new(), [0u8; 4096]);
        while let Ok(n) = stderr.read(&mut buf) {
            if n == 0 {
                break;
            }
            tail.extend_from_slice(&buf[..n]);
            if tail.len() > 16_384 {
                tail.drain(..tail.len() - 8192);
            }
        }
        tail
    });
    let deadline = Instant::now() + PROCESS_TIMEOUT;
    let status = loop {
        if let Some(status) = child.try_wait().map_err(io_err)? {
            break status;
        }
        let cancelled = cancel.load(Ordering::SeqCst);
        if cancelled || Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(if cancelled {
                err_cancelled()
            } else {
                "انتهت مهلة المعالجة / Processing timed out.".into()
            });
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let tail = reader.join().unwrap_or_default();
    check(cancel)?;
    if status.success() {
        return Ok(());
    }
    let text = String::from_utf8_lossy(&tail[tail.len().saturating_sub(3000)..]).trim().to_string();
    let name = exe.file_stem().and_then(|s| s.to_str()).unwrap_or("engine");
    Err(format!("{name}: {text}"))
}

pub struct Job {
    pub inputs: Vec<PathBuf>,
    pub output_dir: PathBuf,
    pub tool: Tool,
    pub options: Options,
}

/// Removes only the random scratch directory this job created.
struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Resolves a destination that may not exist yet without creating anything:
/// canonical deepest existing ancestor + remaining plain components.
pub fn resolve_destination(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err(err_invalid_options());
    }
    let mut existing = path.to_path_buf();
    let mut rest = Vec::new();
    while !existing.exists() {
        let name = existing.file_name().ok_or_else(err_invalid_options)?.to_os_string();
        rest.push(name);
        if !existing.pop() {
            return Err(err_invalid_options());
        }
    }
    let mut out = dunce::canonicalize(&existing).map_err(io_err)?;
    for part in rest.iter().rev() {
        if !matches!(Path::new(part).components().next(), Some(Component::Normal(_))) {
            return Err(err_invalid_options());
        }
        out.push(part);
    }
    Ok(out)
}

pub fn default_output_dir(first_input: &Path) -> PathBuf {
    first_input.parent().unwrap_or(Path::new("/")).join("Zawiya Exports")
}

type Staged = Vec<(PathBuf, String)>;

pub fn run(job: &Job, engines: &Engines, cancel: &Cancel) -> Result<Vec<PathBuf>, String> {
    job.options.validate()?;
    check(cancel)?;
    if job.inputs.is_empty() || job.inputs.len() > MAX_INPUTS {
        return Err(err_invalid_options());
    }
    let mut inputs = Vec::with_capacity(job.inputs.len());
    for raw in &job.inputs {
        let label = raw.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let input = dunce::canonicalize(raw).map_err(|_| err_invalid_file(&label))?;
        let meta = fs::metadata(&input).map_err(|_| err_invalid_file(&label))?;
        if !job.tool.accepts(Kind::detect(&input)) {
            return Err(err_unsupported(&label));
        }
        if !(meta.is_file() || (job.tool == Tool::Zip && meta.is_dir())) {
            return Err(err_invalid_file(&label));
        }
        if meta.is_file() {
            File::open(&input).map_err(|_| err_invalid_file(&label))?;
        }
        inputs.push(input);
    }
    if !job.tool.grouped() && inputs.len() != 1 {
        return Err(err_invalid_options());
    }
    let destination = resolve_destination(&job.output_dir)?;
    for input in inputs.iter().filter(|i| i.is_dir()) {
        if destination.starts_with(input) {
            return Err("اختر مجلد إخراج خارج المجلد المراد أرشفته / Output must be outside the source folder.".into());
        }
    }
    fs::create_dir_all(&destination).map_err(io_err)?;
    let scratch_path = destination.join(format!(".zawiya-work-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&scratch_path).map_err(io_err)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&scratch_path, fs::Permissions::from_mode(0o700));
    }
    let scratch = Scratch(scratch_path);
    let staged = produce(job, &inputs, &scratch.0, engines, cancel)?;
    check(cancel)?;
    if staged.is_empty() {
        return Err("لا توجد مخرجات / No output produced.".into());
    }
    let mut published = Vec::new();
    let result = (|| {
        for (source, name) in &staged {
            check(cancel)?;
            if fs::metadata(source).map(|m| m.len()).unwrap_or(0) == 0 {
                return Err("مخرج فارغ / Empty output.".to_string());
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(source, fs::Permissions::from_mode(0o600));
            }
            published.push(publish(source, &destination, name).map_err(io_err)?);
        }
        Ok(())
    })();
    if let Err(e) = result {
        for path in &published {
            let _ = fs::remove_file(path);
        }
        return Err(e);
    }
    Ok(published)
}

/// No-clobber publish: hard link (atomic, fails on existing names) with a create_new copy
/// fallback for volumes without hard links. Names: `x.ext`, `x-2.ext`, `x-3.ext`…
pub fn publish(source: &Path, destination: &Path, desired: &str) -> io::Result<PathBuf> {
    let (stem, ext) = desired.rsplit_once('.').unwrap_or((desired, ""));
    for n in 0..10_000u32 {
        let name = match (n, ext.is_empty()) {
            (0, _) => desired.to_string(),
            (_, true) => format!("{stem}-{}", n + 1),
            (_, false) => format!("{stem}-{}.{ext}", n + 1),
        };
        let target = destination.join(name);
        match fs::hard_link(source, &target) {
            Ok(()) => return Ok(target),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(_) => {}
        }
        match OpenOptions::new().write(true).create_new(true).open(&target) {
            Ok(mut file) => {
                let copied = File::open(source).and_then(|mut src| io::copy(&mut src, &mut file));
                drop(file);
                return match copied {
                    Ok(_) => Ok(target),
                    Err(e) => {
                        let _ = fs::remove_file(&target); // created by us above
                        Err(e)
                    }
                };
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::other("تعذر إنشاء اسم إخراج فريد / Could not allocate an output name."))
}

fn stem_of(path: &Path) -> String {
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
    stem.chars().take(160).collect()
}

fn preferred_image_format(path: &Path, engines: &Engines) -> &'static str {
    let ext = match ext_of(path).as_str() {
        "jpeg" | "jpg" => "jpg",
        "tif" | "tiff" => "tiff",
        "png" => "png",
        "webp" => "webp",
        "bmp" => "bmp",
        _ => "png",
    };
    if engines.formats(Kind::Image).contains(&ext) {
        ext
    } else {
        "png"
    }
}

fn produce(
    job: &Job,
    inputs: &[PathBuf],
    scratch: &Path,
    engines: &Engines,
    cancel: &Cancel,
) -> Result<Staged, String> {
    let input = &inputs[0];
    let kind = Kind::detect(input);
    let base = format!("{}-zawiya", stem_of(input));
    let opts = &job.options;
    let out = |n: usize, ext: &str| scratch.join(format!("out-{n}.{ext}"));
    match job.tool {
        Tool::Zip => {
            let path = out(0, "zip");
            zip_paths(inputs, &path, cancel)?;
            Ok(vec![(path, format!("{base}.zip"))])
        }
        Tool::ImagesToPdf => {
            let ffmpeg = engines.ffmpeg()?;
            let mut jpegs = Vec::new();
            for (i, source) in inputs.iter().enumerate() {
                check(cancel)?;
                let jpg = out(i, "jpg");
                let mut args = ffmpeg_input(source, Kind::Image);
                args.extend(image_args("jpg", 95, None));
                args.push(file_arg(&jpg));
                run_process(ffmpeg, &args, scratch, cancel)?;
                jpegs.push(jpg);
            }
            let pdf = out(9999, "pdf");
            crate::pdf::images_to_pdf(&jpegs, &pdf)?;
            Ok(vec![(pdf, format!("{base}.pdf"))])
        }
        Tool::MergePdf => {
            let pdf = out(0, "pdf");
            crate::pdf::merge(inputs, &pdf, cancel)?;
            Ok(vec![(pdf, format!("{base}.pdf"))])
        }
        Tool::SplitPdf => crate::pdf::split(input, scratch, &base, cancel),
        Tool::ExtractText => {
            let text = if kind == Kind::Pdf {
                crate::pdf::text_with_ocr(engines, input, scratch, cancel)?
            } else {
                let png = out(0, "png");
                let mut args = ffmpeg_input(input, Kind::Image);
                args.extend(image_args("png", 100, Some(crate::ocr::max_dimension())));
                args.push(file_arg(&png));
                run_process(engines.ffmpeg()?, &args, scratch, cancel)?;
                crate::ocr::recognize(&png)?
            };
            if text.trim().is_empty() {
                return Err("لم يُكتشف نص قابل للاستخراج / No recognizable text found.".into());
            }
            let path = out(1, "txt");
            fs::write(&path, text).map_err(io_err)?;
            Ok(vec![(path, format!("{base}.txt"))])
        }
        Tool::Convert if kind == Kind::Subtitle => {
            if !engines.formats(Kind::Subtitle).contains(&opts.format.as_str()) {
                return Err(err_unsupported(&opts.format));
            }
            if fs::metadata(input).map_err(io_err)?.len() > 20_000_000 {
                return Err(err_invalid_options());
            }
            let raw = fs::read_to_string(input).map_err(|_| err_invalid_file("UTF-8"))?;
            let path = out(0, &opts.format);
            fs::write(&path, subtitle_convert(&raw, &opts.format)?).map_err(io_err)?;
            Ok(vec![(path, format!("{base}.{}", opts.format))])
        }
        Tool::Convert if kind == Kind::Pdf => {
            let format = opts.format.as_str();
            if !engines.formats(Kind::Pdf).contains(&format) {
                return Err(err_unsupported(format));
            }
            if format == "txt" || format == "md" {
                let text = crate::pdf::text_pages(engines, input, cancel)?.join("\n\n");
                if text.trim().is_empty() {
                    return Err("الـPDF مصوّر؛ استخدم استخراج النص OCR / Use OCR for this scanned PDF.".into());
                }
                let path = out(0, format);
                fs::write(&path, text).map_err(io_err)?;
                return Ok(vec![(path, format!("{base}.{format}"))]);
            }
            let ffmpeg = engines.ffmpeg()?;
            let mut staged = Vec::new();
            crate::pdf::render_pages(engines, input, opts.max_dimension, None, scratch, cancel, |index, raw, w, h| {
                let path = out(index, format);
                let mut args = rawvideo_input(raw, w, h);
                args.extend(image_args(format, opts.quality, None));
                args.push(file_arg(&path));
                run_process(ffmpeg, &args, scratch, cancel)?;
                staged.push((path, format!("{base}.page-{:03}.{format}", index + 1)));
                Ok(())
            })?;
            Ok(staged)
        }
        Tool::Convert | Tool::Compress | Tool::Resize | Tool::StripMetadata if kind == Kind::Image => {
            let format = match job.tool {
                Tool::Resize | Tool::StripMetadata => preferred_image_format(input, engines),
                _ => opts.format.as_str(),
            };
            if !engines.formats(Kind::Image).contains(&format) {
                return Err(err_unsupported(format));
            }
            let ffmpeg = engines.ffmpeg()?;
            let max = (job.tool == Tool::Resize).then_some(opts.max_dimension);
            let encoded = if format == "pdf" { "jpg" } else { format };
            let quality = if format == "pdf" { 95 } else { opts.quality };
            let path = out(0, encoded);
            let mut args = ffmpeg_input(input, Kind::Image);
            args.extend(image_args(encoded, quality, max));
            args.push(file_arg(&path));
            run_process(ffmpeg, &args, scratch, cancel)?;
            if format == "pdf" {
                let pdf = out(1, "pdf");
                crate::pdf::images_to_pdf(&[path], &pdf)?;
                return Ok(vec![(pdf, format!("{base}.pdf"))]);
            }
            Ok(vec![(path, format!("{base}.{format}"))])
        }
        Tool::Convert | Tool::Compress | Tool::StripMetadata | Tool::Trim | Tool::VideoFrame | Tool::ExtractAudio => {
            if !matches!(kind, Kind::Audio | Kind::Video) {
                return Err(err_unsupported(&input.file_name().unwrap_or_default().to_string_lossy()));
            }
            let ffmpeg = engines.ffmpeg()?;
            let format = media_format(job.tool, kind, &ext_of(input), &opts.format);
            if !format.bytes().all(|b| b.is_ascii_alphanumeric()) || format.is_empty() || format.len() > 5 {
                return Err(err_unsupported(&format));
            }
            let allowed = match job.tool {
                Tool::StripMetadata | Tool::VideoFrame => true,
                Tool::ExtractAudio => {
                    ["mp3", "m4a", "wav"].contains(&format.as_str()) && engines.formats(kind).contains(&format.as_str())
                }
                _ => engines.formats(kind).contains(&format.as_str()),
            };
            if !allowed {
                return Err(err_unsupported(&format));
            }
            let path = out(0, &format);
            let mut args = ffmpeg_input(input, kind);
            args.extend(media_tool_args(job.tool, &format, opts));
            args.push(file_arg(&path));
            run_process(ffmpeg, &args, scratch, cancel)?;
            Ok(vec![(path, format!("{base}.{format}"))])
        }
        _ => Err(err_unsupported(&format!("{:?}", job.tool))),
    }
}

pub fn media_format(tool: Tool, kind: Kind, input_ext: &str, chosen: &str) -> String {
    match tool {
        Tool::VideoFrame => "png".into(),
        Tool::StripMetadata => input_ext.into(),
        Tool::Compress | Tool::Trim => if kind == Kind::Video { "mp4" } else { "m4a" }.into(),
        _ => chosen.into(),
    }
}

pub(crate) fn file_arg(path: &Path) -> String {
    // `file:` stops names such as `concat:…` or `subfile,…` from being read as protocols.
    format!("file:{}", path.display())
}

pub fn ffmpeg_input(input: &Path, kind: Kind) -> Vec<String> {
    let mut args: Vec<String> =
        ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe"]
            .map(String::from)
            .to_vec();
    if kind == Kind::Image {
        if ["heic", "heif", "avif"].contains(&ext_of(input).as_str()) {
            args.extend(["-format_whitelist", "mov"].map(String::from));
        } else {
            // image2 with patterns disabled: `%d` or `*` in a file name stays literal.
            args.extend(["-format_whitelist", "image2", "-f", "image2", "-pattern_type", "none"].map(String::from));
        }
        args.extend(["-max_pixels", "100000000"].map(String::from));
    } else {
        args.extend(["-format_whitelist", MEDIA_DEMUXERS].map(String::from));
    }
    args.push("-i".into());
    args.push(file_arg(input));
    args
}

pub(crate) fn rawvideo_input(raw: &Path, width: u32, height: u32) -> Vec<String> {
    let mut args: Vec<String> = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-n",
        "-protocol_whitelist",
        "file",
        "-format_whitelist",
        "rawvideo",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgba",
        "-s",
    ]
    .map(String::from)
    .to_vec();
    args.push(format!("{width}x{height}"));
    args.push("-i".into());
    args.push(file_arg(raw));
    args
}

/// Still-image encode arguments. JPEG/BMP flatten transparency onto white like the Mac app
/// (negate → premultiply over black → negate == composite over white).
pub fn image_args(format: &str, quality: u32, max_dimension: Option<u32>) -> Vec<String> {
    let mut filters = Vec::new();
    if let Some(n) = max_dimension {
        filters
            .push(format!("scale=w='min(iw,{n})':h='min(ih,{n})':force_original_aspect_ratio=decrease:flags=lanczos"));
    }
    if format == "jpg" || format == "bmp" {
        filters.push("format=rgba,negate,premultiply=inplace=1,negate".into());
    }
    let mut args: Vec<String> = vec!["-map".into(), "0:v:0".into()];
    if !filters.is_empty() {
        args.push("-vf".into());
        args.push(filters.join(","));
    }
    let q = quality.clamp(1, 100);
    let codec: Vec<String> = match format {
        "jpg" => vec![
            "-c:v".into(),
            "mjpeg".into(),
            "-q:v".into(),
            (2 + (100 - q) * 29 / 99).to_string(),
            "-pix_fmt".into(),
            "yuvj444p".into(),
        ],
        "png" => vec!["-c:v".into(), "png".into()],
        "webp" => {
            vec!["-c:v".into(), "libwebp".into(), "-quality".into(), q.to_string(), "-lossless".into(), "0".into()]
        }
        "tiff" => vec!["-c:v".into(), "tiff".into()],
        "bmp" => vec!["-c:v".into(), "bmp".into(), "-pix_fmt".into(), "bgr24".into()],
        _ => vec![],
    };
    args.extend(codec);
    args.extend(
        ["-frames:v", "1", "-update", "1", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact"]
            .map(String::from),
    );
    args
}

/// Same codec choices as Converter.swift `mediaArguments`.
pub fn media_args(format: &str, quality: u32) -> Vec<String> {
    let crf = ((18.0 + (100.0 - quality as f64) * 0.32) as i64).to_string();
    let audio_rate = format!("{}k", 64 + quality * 192 / 100);
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match format {
        "mp4" | "mov" | "mkv" => {
            let mut a = s(&[
                "-map",
                "0:v:0?",
                "-map",
                "0:a:0?",
                "-c:v",
                "libx264",
                "-preset",
                "fast",
                "-crf",
                &crf,
                "-vf",
                "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
            ]);
            if format != "mkv" {
                a.extend(s(&["-movflags", "+faststart"]));
            }
            a
        }
        "webm" => s(&[
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c:v",
            "libsvtav1",
            "-preset",
            "10",
            "-crf",
            &crf,
            "-c:a",
            "libopus",
        ]),
        "avi" => s(&["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame"]),
        "gif" => s(&[
            "-an",
            "-filter_complex",
            "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
            "-loop",
            "0",
        ]),
        "mp3" => s(&["-vn", "-c:a", "libmp3lame", "-q:a", &((100 - quality.min(100)) * 9 / 90).min(9).to_string()]),
        "m4a" => s(&["-vn", "-c:a", "aac", "-b:a", &audio_rate]),
        "wav" => s(&["-vn", "-c:a", "pcm_s16le"]),
        "flac" => s(&["-vn", "-c:a", "flac"]),
        "ogg" | "opus" => s(&["-vn", "-c:a", "libopus", "-b:a", &audio_rate]),
        "aiff" => s(&["-vn", "-c:a", "pcm_s16be"]),
        "wma" => s(&["-vn", "-c:a", "wmav1", "-b:a", "128k"]),
        _ => vec![],
    }
}

pub fn media_tool_args(tool: Tool, format: &str, opts: &Options) -> Vec<String> {
    let mut args = Vec::new();
    if tool == Tool::Trim {
        args.extend(["-ss".into(), opts.start.to_string(), "-t".into(), opts.duration.to_string()]);
    }
    match tool {
        Tool::VideoFrame => args.extend([
            "-ss".into(),
            opts.start.to_string(),
            "-frames:v".into(),
            "1".into(),
            "-update".into(),
            "1".into(),
        ]),
        Tool::StripMetadata => {
            args.extend(["-map", "0", "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1"].map(String::from))
        }
        _ => {
            args.extend(media_args(format, opts.quality));
            args.extend(["-map_metadata", "-1", "-map_chapters", "-1"].map(String::from));
        }
    }
    args
}

/// SRT / VTT / TXT conversion keeping text (Arabic included) and timing. Port of `Subtitle.convert`.
pub fn subtitle_convert(raw: &str, format: &str) -> Result<String, String> {
    if !["srt", "vtt", "txt"].contains(&format) || raw.len() > 20_000_000 {
        return Err(err_invalid_options());
    }
    let pattern = regex::Regex::new(
        r"^((?:\d{2,}:)?\d{2}:\d{2})[.,](\d{3})\s+-->\s+((?:\d{2,}:)?\d{2}:\d{2})[.,](\d{3})(?:\s+.*)?$",
    )
    .expect("valid regex");
    let text = raw.trim_start_matches('\u{feff}').replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = text.split('\n').collect();
    let stamp = |value: &str, ms: &str| -> Result<String, String> {
        let fields: Vec<u32> = value.split(':').filter_map(|f| f.parse().ok()).collect();
        let n = fields.len();
        let ok = (2..=3).contains(&n) && fields[n - 2..].iter().all(|f| *f <= 59) && (n == 2 || fields[0] <= 9999);
        if !ok {
            return Err(err_invalid_file("Subtitle timing"));
        }
        Ok(format!("{}{value}.{ms}", if n == 2 { "00:" } else { "" }))
    };
    let mut cues: Vec<(String, Vec<&str>)> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].trim();
        if let Some(c) = pattern.captures(line) {
            let time = format!("{} --> {}", stamp(&c[1], &c[2])?, stamp(&c[3], &c[4])?);
            i += 1;
            let mut body = Vec::new();
            while i < lines.len() && !lines[i].trim().is_empty() {
                body.push(lines[i]);
                i += 1;
            }
            cues.push((time, body));
        } else {
            i += 1;
        }
    }
    if cues.is_empty() {
        return Err(err_invalid_file("Subtitle timing"));
    }
    if format == "txt" {
        return Ok(cues.iter().flat_map(|c| c.1.iter().copied()).collect::<Vec<_>>().join("\n") + "\n");
    }
    let body = cues
        .iter()
        .enumerate()
        .map(|(i, (time, lines))| match format {
            "srt" => format!("{}\n{}\n{}", i + 1, time.replace('.', ","), lines.join("\n")),
            _ => format!("{time}\n{}", lines.join("\n")),
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    Ok(format!("{}{body}\n", if format == "vtt" { "WEBVTT\n\n" } else { "" }))
}

/// ZIP of files/folders relative to their common parent. Symlinks are stored as links, never followed.
pub fn zip_paths(inputs: &[PathBuf], out: &Path, cancel: &Cancel) -> Result<(), String> {
    use zip::write::SimpleFileOptions;
    let mut common = inputs[0].parent().map(Path::to_path_buf).unwrap_or_default();
    while !inputs.iter().all(|p| p.starts_with(&common)) {
        if !common.pop() {
            break;
        }
    }
    let file = OpenOptions::new().write(true).create_new(true).open(out).map_err(io_err)?;
    let mut writer = zip::ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated).large_file(true);
    let mut entries = 0usize;
    let mut stack: Vec<PathBuf> = inputs.iter().rev().cloned().collect();
    while let Some(path) = stack.pop() {
        check(cancel)?;
        entries += 1;
        if entries > 500_000 {
            return Err("الأرشيف كبير جداً / Too many entries.".into());
        }
        let rel = path.strip_prefix(&common).map_err(io_err)?;
        let name = rel.components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/");
        let meta = fs::symlink_metadata(&path).map_err(io_err)?;
        if meta.file_type().is_symlink() {
            let target = fs::read_link(&path).map_err(io_err)?;
            writer.add_symlink(name, target.to_string_lossy(), options).map_err(io_err)?;
        } else if meta.is_dir() {
            writer.add_directory(format!("{name}/"), options).map_err(io_err)?;
            let mut children: Vec<PathBuf> =
                fs::read_dir(&path).map_err(io_err)?.filter_map(|e| e.ok().map(|e| e.path())).collect();
            children.sort();
            stack.extend(children.into_iter().rev());
        } else if meta.is_file() {
            writer.start_file(name, options).map_err(io_err)?;
            let mut src = File::open(&path).map_err(io_err)?;
            io::copy(&mut src, &mut writer).map_err(io_err)?;
        }
    }
    writer.finish().map_err(io_err)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("zawiya-test-{name}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn publish_never_overwrites() {
        let dir = tmp("publish");
        let src = dir.join("staged.txt");
        fs::write(&src, "new").unwrap();
        fs::write(dir.join("a-zawiya.txt"), "old").unwrap();
        let first = publish(&src, &dir, "a-zawiya.txt").unwrap();
        assert_eq!(first.file_name().unwrap(), "a-zawiya-2.txt");
        let second = publish(&src, &dir, "a-zawiya.txt").unwrap();
        assert_eq!(second.file_name().unwrap(), "a-zawiya-3.txt");
        assert_eq!(fs::read_to_string(dir.join("a-zawiya.txt")).unwrap(), "old");
        let page = publish(&src, &dir, "a-zawiya.page-001.pdf").unwrap();
        assert_eq!(page.file_name().unwrap(), "a-zawiya.page-001.pdf");
        let page2 = publish(&src, &dir, "a-zawiya.page-001.pdf").unwrap();
        assert_eq!(page2.file_name().unwrap(), "a-zawiya.page-001-2.pdf");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn option_bounds() {
        let ok = Options::default();
        assert!(ok.validate().is_ok());
        for bad in [
            Options { quality: 0, ..Options::default() },
            Options { quality: 101, ..Options::default() },
            Options { max_dimension: 15, ..Options::default() },
            Options { max_dimension: 16001, ..Options::default() },
            Options { start: -1.0, ..Options::default() },
            Options { start: f64::NAN, ..Options::default() },
            Options { duration: 0.0, ..Options::default() },
            Options { duration: 604_801.0, ..Options::default() },
            Options { format: "../x".into(), ..Options::default() },
            Options { format: "MP4".into(), ..Options::default() },
        ] {
            assert!(bad.validate().is_err(), "{bad:?}");
        }
    }

    #[test]
    fn subtitles_keep_arabic_and_timing() {
        let srt = "\u{feff}1\r\n00:00:01,500 --> 00:00:03,000\r\nمرحبا بالعالم\r\nسطر ثانٍ\r\n\r\n2\r\n01:02,000 --> 01:04,250\r\nHello\r\n";
        let vtt = subtitle_convert(srt, "vtt").unwrap();
        assert_eq!(
            vtt,
            "WEBVTT\n\n00:00:01.500 --> 00:00:03.000\nمرحبا بالعالم\nسطر ثانٍ\n\n00:01:02.000 --> 00:01:04.250\nHello\n"
        );
        let back = subtitle_convert(&vtt, "srt").unwrap();
        assert_eq!(
            back,
            "1\n00:00:01,500 --> 00:00:03,000\nمرحبا بالعالم\nسطر ثانٍ\n\n2\n00:01:02,000 --> 00:01:04,250\nHello\n"
        );
        assert_eq!(subtitle_convert(srt, "txt").unwrap(), "مرحبا بالعالم\nسطر ثانٍ\nHello\n");
        assert!(subtitle_convert("no cues here", "srt").is_err());
        assert!(subtitle_convert("00:00:61,000 --> 00:00:62,000\nx", "srt").is_err());
        assert!(subtitle_convert(srt, "ass").is_err());
    }

    #[test]
    fn ffmpeg_args_per_format() {
        for f in ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        {
            assert!(!media_args(f, 80).is_empty(), "{f}");
        }
        let mp4 = media_args("mp4", 80).join(" ");
        assert!(mp4.contains("-c:v libx264") && mp4.contains("-crf 24") && mp4.contains("+faststart"));
        assert!(!media_args("mkv", 80).join(" ").contains("faststart"));
        assert!(media_args("webm", 80).join(" ").contains("libsvtav1"));
        assert_eq!(media_args("mp3", 100).join(" "), "-vn -c:a libmp3lame -q:a 0");
        assert_eq!(media_args("mp3", 10).join(" "), "-vn -c:a libmp3lame -q:a 9");
        assert!(media_args("m4a", 50).join(" ").contains("-b:a 160k"));
        assert!(media_args("xyz", 80).is_empty());
        let jpg = image_args("jpg", 100, Some(1600)).join(" ");
        assert!(
            jpg.contains("min(iw,1600)") && jpg.contains("mjpeg") && jpg.contains("-q:v 2") && jpg.contains("negate")
        );
        assert!(image_args("png", 80, None).join(" ").contains("-c:v png"));
        assert!(!image_args("png", 80, None).join(" ").contains("negate"));
        assert!(image_args("webp", 78, None).join(" ").contains("-quality 78"));
        let input = ffmpeg_input(Path::new("/x/concat:a%d.mp4"), Kind::Video).join(" ");
        assert!(
            input.contains("-protocol_whitelist file,pipe")
                && input.contains("-i file:/x/concat:a%d.mp4")
                && input.contains("-n")
        );
        assert!(ffmpeg_input(Path::new("/x/a%03d.png"), Kind::Image).join(" ").contains("-pattern_type none"));
        let trim =
            media_tool_args(Tool::Trim, "mp4", &Options { start: 1.5, duration: 2.0, ..Options::default() }).join(" ");
        assert!(trim.starts_with("-ss 1.5 -t 2 "));
        assert!(media_tool_args(Tool::StripMetadata, "mp4", &Options::default()).join(" ").contains("-c copy"));
        assert_eq!(media_format(Tool::Compress, Kind::Audio, "wav", "mp3"), "m4a");
        assert_eq!(media_format(Tool::VideoFrame, Kind::Video, "mov", "mp4"), "png");
    }

    #[test]
    fn format_catalog_follows_encoders() {
        let none = Engines::default();
        assert!(none.formats(Kind::Image).is_empty());
        assert_eq!(none.formats(Kind::Subtitle), vec!["srt", "vtt", "txt"]);
        let basic = Engines { ffmpeg: Some("/x/ffmpeg".into()), ..Default::default() };
        assert!(!basic.formats(Kind::Image).contains(&"webp"));
        assert!(!basic.formats(Kind::Audio).contains(&"mp3"));
        let full = Engines {
            ffmpeg: Some("/x/ffmpeg".into()),
            encoders: ["libwebp", "libmp3lame", "libopus", "libsvtav1"].map(String::from).into(),
            ..Default::default()
        };
        assert!(full.formats(Kind::Image).contains(&"webp") && full.formats(Kind::Video).contains(&"webm"));
    }

    #[test]
    fn zip_refuses_output_inside_source_and_keeps_symlinks() {
        let dir = tmp("zip");
        let folder = dir.join("src");
        fs::create_dir_all(folder.join("inner")).unwrap();
        fs::write(folder.join("inner/a.txt"), "مرحبا").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc/hosts", folder.join("link")).unwrap();
        let job = Job {
            inputs: vec![folder.clone()],
            output_dir: folder.join("Zawiya Exports"),
            tool: Tool::Zip,
            options: Options::default(),
        };
        let cancel: Cancel = Default::default();
        assert!(run(&job, &Engines::default(), &cancel).unwrap_err().contains("outside"));
        assert!(!folder.join("Zawiya Exports").exists());
        let job = Job { output_dir: dir.join("out"), ..job };
        let outputs = run(&job, &Engines::default(), &cancel).unwrap();
        assert_eq!(outputs[0].file_name().unwrap(), "src-zawiya.zip");
        let mut archive = zip::ZipArchive::new(File::open(&outputs[0]).unwrap()).unwrap();
        let names: Vec<String> =
            (0..archive.len()).map(|i| archive.by_index(i).unwrap().name().unwrap().to_string()).collect();
        assert!(names.contains(&"src/inner/a.txt".to_string()));
        #[cfg(unix)]
        {
            let link = archive.by_name("src/link").unwrap();
            assert!(link.is_symlink());
        }
        // Second run never clobbers the first archive; scratch dirs are gone.
        let again = run(&job, &Engines::default(), &cancel).unwrap();
        assert_eq!(again[0].file_name().unwrap(), "src-zawiya-2.zip");
        let leftovers: Vec<_> = fs::read_dir(dir.join("out"))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with(".zawiya-work"))
            .collect();
        assert!(leftovers.is_empty());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn rejects_bad_inputs() {
        let dir = tmp("reject");
        let cancel: Cancel = Default::default();
        let fake = dir.join("a.exe");
        fs::write(&fake, "x").unwrap();
        let job =
            |inputs: Vec<PathBuf>, tool| Job { inputs, output_dir: dir.join("out"), tool, options: Options::default() };
        assert!(run(&job(vec![fake.clone()], Tool::Convert), &Engines::default(), &cancel).is_err());
        assert!(run(&job(vec![dir.join("missing.png")], Tool::Convert), &Engines::default(), &cancel).is_err());
        let sub = dir.join("a.srt");
        fs::write(&sub, "1\n00:00:01,000 --> 00:00:02,000\nنص\n").unwrap();
        assert!(run(&job(vec![sub.clone(), sub.clone()], Tool::Convert), &Engines::default(), &cancel).is_err());
        cancel.store(true, Ordering::SeqCst);
        assert_eq!(run(&job(vec![sub], Tool::Convert), &Engines::default(), &cancel).unwrap_err(), err_cancelled());
        fs::remove_dir_all(dir).unwrap();
    }
}
