//! PDF tools: merge/split/images→PDF with lopdf (pure Rust), render/text with a bundled PDFium.

use crate::engine::{check, file_arg, image_args, rawvideo_input, run_process, Cancel, Engines, MAX_PDF_PAGES};
use lopdf::{dictionary, Dictionary, Document, Object, ObjectId, Stream};
use pdfium_render::prelude::*;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn invalid(path: &Path) -> String {
    format!("تعذر قراءة الملف / Cannot read: {}", path.file_name().unwrap_or_default().to_string_lossy())
}
fn write_failed(e: impl std::fmt::Display) -> String {
    format!("تعذر حفظ PDF / PDF write failed: {e}")
}

fn load(path: &Path) -> Result<Document, String> {
    let doc = Document::load(path).map_err(|_| invalid(path))?;
    let pages = doc.get_pages().len();
    if doc.is_encrypted() || pages == 0 || pages > MAX_PDF_PAGES {
        return Err(invalid(path));
    }
    Ok(doc)
}

fn is_page_node(obj: &Object) -> bool {
    matches!(obj.type_name(), Ok(b"Page") | Ok(b"Pages"))
}

fn push_refs(obj: &Object, stack: &mut Vec<ObjectId>) {
    match obj {
        Object::Reference(id) => stack.push(*id),
        Object::Array(items) => items.iter().for_each(|o| push_refs(o, stack)),
        Object::Dictionary(dict) => dict.iter().for_each(|(_, o)| push_refs(o, stack)),
        Object::Stream(stream) => stream.dict.iter().for_each(|(_, o)| push_refs(o, stack)),
        _ => {}
    }
}

/// Copies one page plus everything it references (never other pages) into `out`,
/// materialising inherited attributes so the page survives a new page tree.
fn copy_page(
    doc: &Document,
    page_id: ObjectId,
    parent: ObjectId,
    out: &mut BTreeMap<ObjectId, Object>,
) -> Result<(), String> {
    let mut page = doc.get_dictionary(page_id).map_err(|e| e.to_string())?.clone();
    for key in [&b"Resources"[..], b"MediaBox", b"CropBox", b"Rotate"] {
        if page.has(key) {
            continue;
        }
        let mut node = page.get(b"Parent").and_then(Object::as_reference).ok();
        for _ in 0..64 {
            let Some(id) = node else { break };
            let Ok(dict) = doc.get_dictionary(id) else { break };
            if let Ok(value) = dict.get(key) {
                page.set(key.to_vec(), value.clone());
                break;
            }
            node = dict.get(b"Parent").and_then(Object::as_reference).ok();
        }
    }
    page.set("Parent", parent);
    let mut stack = Vec::new();
    for (key, value) in page.iter() {
        if key != b"Parent" {
            push_refs(value, &mut stack);
        }
    }
    out.insert(page_id, Object::Dictionary(page));
    while let Some(id) = stack.pop() {
        if out.contains_key(&id) {
            continue;
        }
        let Ok(obj) = doc.get_object(id) else { continue };
        if is_page_node(obj) {
            continue;
        } // dangling refs to other pages read as null
        push_refs(obj, &mut stack);
        out.insert(id, obj.clone());
    }
    Ok(())
}

/// Builds a fresh document from `(document, page ids)` parts. Object ids must not collide.
fn assemble(parts: &[(&Document, Vec<ObjectId>)], out_path: &Path, cancel: &Cancel) -> Result<(), String> {
    let max = parts.iter().map(|(d, _)| d.max_id).max().unwrap_or(0);
    let (pages_id, catalog_id) = ((max + 1, 0), (max + 2, 0));
    let mut objects = BTreeMap::new();
    let mut kids = Vec::new();
    for (doc, pages) in parts {
        for id in pages {
            check(cancel)?;
            copy_page(doc, *id, pages_id, &mut objects)?;
            kids.push(Object::Reference(*id));
        }
    }
    let mut out = Document::with_version("1.7");
    out.objects = objects;
    out.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! { "Type" => "Pages", "Count" => kids.len() as i64, "Kids" => kids }),
    );
    out.objects.insert(catalog_id, Object::Dictionary(dictionary! { "Type" => "Catalog", "Pages" => pages_id }));
    out.trailer.set("Root", catalog_id);
    out.max_id = max + 2;
    out.renumber_objects();
    out.compress();
    out.save(out_path).map_err(write_failed)?;
    // Re-open to make sure what we wrote is readable with the expected page count.
    let expected = parts.iter().map(|(_, p)| p.len()).sum::<usize>();
    let check_doc = Document::load(out_path).map_err(write_failed)?;
    if check_doc.get_pages().len() != expected {
        return Err(write_failed("page count"));
    }
    Ok(())
}

pub fn merge(inputs: &[PathBuf], out: &Path, cancel: &Cancel) -> Result<(), String> {
    let mut docs = Vec::new();
    let mut next = 1;
    let mut total = 0;
    for path in inputs {
        check(cancel)?;
        let mut doc = load(path)?;
        total += doc.get_pages().len();
        if total > MAX_PDF_PAGES {
            return Err(invalid(path));
        }
        doc.renumber_objects_with(next);
        next = doc.max_id + 1;
        docs.push(doc);
    }
    let parts: Vec<_> = docs.iter().map(|d| (d, d.get_pages().into_values().collect())).collect();
    assemble(&parts, out, cancel)
}

pub fn split(input: &Path, scratch: &Path, base: &str, cancel: &Cancel) -> Result<Vec<(PathBuf, String)>, String> {
    let doc = load(input)?;
    let mut staged = Vec::new();
    for (number, id) in doc.get_pages() {
        let path = scratch.join(format!("out-{number}.pdf"));
        assemble(&[(&doc, vec![id])], &path, cancel)?;
        staged.push((path, format!("{base}.page-{number:03}.pdf")));
    }
    Ok(staged)
}

/// Width, height and component count from a baseline/progressive JPEG SOF marker.
pub fn jpeg_info(data: &[u8]) -> Option<(u32, u32, u8)> {
    if data.get(..2)? != [0xFF, 0xD8] {
        return None;
    }
    let mut i = 2;
    while i + 9 < data.len() {
        if data[i] != 0xFF {
            i += 1;
            continue;
        }
        let marker = data[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        if (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker) {
            let h = u16::from_be_bytes([data[i + 5], data[i + 6]]) as u32;
            let w = u16::from_be_bytes([data[i + 7], data[i + 8]]) as u32;
            return (w > 0 && h > 0).then_some((w, h, data[i + 9]));
        }
        i += 2 + len;
    }
    None
}

/// One page per JPEG, page size = pixel size (capped to the 14400pt PDF limit).
pub fn images_to_pdf(jpegs: &[PathBuf], out: &Path) -> Result<(), String> {
    let mut doc = Document::with_version("1.7");
    let pages_id = doc.new_object_id();
    let mut kids = Vec::new();
    for path in jpegs {
        let data = fs::read(path).map_err(write_failed)?;
        let (w, h, comps) = jpeg_info(&data).ok_or_else(|| invalid(path))?;
        let space = match comps {
            1 => "DeviceGray",
            4 => "DeviceCMYK",
            _ => "DeviceRGB",
        };
        let image = doc.add_object(Stream::new(
            dictionary! { "Type" => "XObject", "Subtype" => "Image", "Width" => w as i64, "Height" => h as i64,
            "ColorSpace" => space, "BitsPerComponent" => 8, "Filter" => "DCTDecode" },
            data,
        ));
        let scale = (14_400.0 / w.max(h) as f64).min(1.0);
        let (pw, ph) = (w as f64 * scale, h as f64 * scale);
        let content = doc
            .add_object(Stream::new(Dictionary::new(), format!("q {pw:.2} 0 0 {ph:.2} 0 0 cm /Im0 Do Q").into_bytes()));
        let page = doc.add_object(dictionary! {
            "Type" => "Page", "Parent" => pages_id, "Contents" => content,
            "MediaBox" => vec![0.into(), 0.into(), Object::Real(pw as f32), Object::Real(ph as f32)],
            "Resources" => dictionary! { "XObject" => dictionary! { "Im0" => image } },
        });
        kids.push(Object::Reference(page));
    }
    let count = kids.len() as i64;
    doc.objects
        .insert(pages_id, Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => kids, "Count" => count }));
    let catalog = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog);
    doc.save(out).map_err(write_failed)?;
    Ok(())
}

static PDFIUM: OnceLock<Result<Pdfium, String>> = OnceLock::new();

fn pdfium(engines: &Engines) -> Result<&'static Pdfium, String> {
    let missing = || "المحرك غير متوفر / Engine unavailable: PDFium (pdfium.dll)".to_string();
    let dir = engines.pdfium_dir.clone().ok_or_else(missing)?;
    PDFIUM
        .get_or_init(|| {
            Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(&dir))
                .map(Pdfium::new)
                .map_err(|e| format!("{}: {e}", missing()))
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn open<'a>(pdfium: &'a Pdfium, input: &Path) -> Result<PdfDocument<'a>, String> {
    let doc = pdfium.load_pdf_from_file(input, None).map_err(|_| invalid(input))?;
    let count = doc.pages().len() as usize;
    if count == 0 || count > MAX_PDF_PAGES {
        return Err(invalid(input));
    }
    Ok(doc)
}

pub fn text_pages(engines: &Engines, input: &Path, cancel: &Cancel) -> Result<Vec<String>, String> {
    let pdfium = pdfium(engines)?;
    let doc = open(pdfium, input)?;
    let mut pages = Vec::new();
    for page in doc.pages().iter() {
        check(cancel)?;
        pages.push(page.text().map(|t| t.all()).unwrap_or_default().trim().to_string());
    }
    Ok(pages)
}

/// Renders pages (all, or `only`) so the longest side is `max` px, writing raw RGBA to a scratch
/// file and handing it to `each(index, raw_path, width, height)`.
pub fn render_pages(
    engines: &Engines,
    input: &Path,
    max: u32,
    only: Option<&[usize]>,
    scratch: &Path,
    cancel: &Cancel,
    mut each: impl FnMut(usize, &Path, u32, u32) -> Result<(), String>,
) -> Result<(), String> {
    let pdfium = pdfium(engines)?;
    let doc = open(pdfium, input)?;
    let raw = scratch.join("page.rgba");
    for (index, page) in doc.pages().iter().enumerate() {
        if only.is_some_and(|o| !o.contains(&index)) {
            continue;
        }
        check(cancel)?;
        let config = PdfRenderConfig::new();
        let config = if page.width().value >= page.height().value {
            config.set_target_width(max as _)
        } else {
            config.set_target_height(max as _)
        };
        let bitmap = page.render_with_config(&config).map_err(|_| invalid(input))?;
        let (w, h) = (bitmap.width() as u32, bitmap.height() as u32);
        let rgba = bitmap.as_rgba_bytes();
        if w == 0 || h == 0 || rgba.len() != (w * h * 4) as usize {
            return Err(invalid(input));
        }
        fs::write(&raw, rgba).map_err(write_failed)?;
        each(index, &raw, w, h)?;
    }
    let _ = fs::remove_file(&raw);
    Ok(())
}

/// Embedded text per page; pages without text go through OCR (Windows only).
pub fn text_with_ocr(engines: &Engines, input: &Path, scratch: &Path, cancel: &Cancel) -> Result<String, String> {
    let mut pages = text_pages(engines, input, cancel)?;
    let empty: Vec<usize> = pages.iter().enumerate().filter(|(_, t)| t.is_empty()).map(|(i, _)| i).collect();
    let mut ocr_error = None;
    if !empty.is_empty() {
        let ffmpeg = engines.ffmpeg.clone().ok_or("المحرك غير متوفر / Engine unavailable: FFmpeg")?;
        let max = crate::ocr::max_dimension().min(3000);
        render_pages(engines, input, max, Some(&empty), scratch, cancel, |index, raw, w, h| {
            let png = scratch.join("ocr-page.png");
            let _ = fs::remove_file(&png);
            let mut args = rawvideo_input(raw, w, h);
            args.extend(image_args("png", 100, None));
            args.push(file_arg(&png));
            run_process(&ffmpeg, &args, scratch, cancel)?;
            match crate::ocr::recognize(&png) {
                Ok(text) => pages[index] = text.trim().to_string(),
                Err(e) => {
                    ocr_error.get_or_insert(e);
                }
            }
            Ok(())
        })?;
    }
    let text = pages.into_iter().filter(|p| !p.is_empty()).collect::<Vec<_>>().join("\n\n");
    match (text.is_empty(), ocr_error) {
        (true, Some(e)) => Err(e),
        _ => Ok(text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny_jpeg(dir: &Path, name: &str, w: u16, h: u16) -> PathBuf {
        // Minimal SOI + SOF0 header is enough for jpeg_info; PDF viewers are not involved here.
        let mut data = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08];
        data.extend(h.to_be_bytes());
        data.extend(w.to_be_bytes());
        data.extend([3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9]);
        let path = dir.join(name);
        fs::write(&path, data).unwrap();
        path
    }

    #[test]
    fn jpeg_dimensions() {
        let dir = std::env::temp_dir();
        let p = tiny_jpeg(&dir, &format!("zawiya-{}.jpg", uuid::Uuid::new_v4()), 640, 200);
        assert_eq!(jpeg_info(&fs::read(&p).unwrap()), Some((640, 200, 3)));
        assert_eq!(jpeg_info(b"not a jpeg"), None);
        fs::remove_file(p).unwrap();
    }

    #[test]
    fn images_merge_split_keep_order() {
        let dir = std::env::temp_dir().join(format!("zawiya-pdf-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let cancel: Cancel = Default::default();
        let a = dir.join("a.pdf");
        let b = dir.join("b.pdf");
        images_to_pdf(&[tiny_jpeg(&dir, "1.jpg", 100, 50), tiny_jpeg(&dir, "2.jpg", 200, 50)], &a).unwrap();
        images_to_pdf(&[tiny_jpeg(&dir, "3.jpg", 300, 50)], &b).unwrap();
        let merged = dir.join("m.pdf");
        merge(&[a, b], &merged, &cancel).unwrap();
        let doc = Document::load(&merged).unwrap();
        let widths: Vec<f32> = doc
            .get_pages()
            .values()
            .map(|id| {
                doc.get_dictionary(*id).unwrap().get(b"MediaBox").unwrap().as_array().unwrap()[2].as_float().unwrap()
            })
            .collect();
        assert_eq!(widths, vec![100.0, 200.0, 300.0]);
        let parts = split(&merged, &dir, "m-zawiya", &cancel).unwrap();
        assert_eq!(parts.len(), 3);
        assert_eq!(parts[2].1, "m-zawiya.page-003.pdf");
        assert_eq!(Document::load(&parts[1].0).unwrap().get_pages().len(), 1);
        fs::remove_dir_all(dir).unwrap();
    }
}
