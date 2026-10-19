"use strict";
// Shared by the main window (app.js) and the quick windows (quick.js): icons, tool names, DOM builder.

const tauri = window.__TAURI__;
const invoke = (cmd, args) => tauri.core.invoke(cmd, args);
const listen = (name, fn) => tauri.event.listen(name, fn);

const ICONS = {
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  theme: '<path d="M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9Z"/>',
  workspace: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  tools: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
  about: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.5"/>',
  drop: '<path d="M12 3v11M7.5 9.5 12 14l4.5-4.5"/><path d="M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  folder: '<path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
  check: '<circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.7 2.7L16.5 9.5"/>',
  alert: '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5M12 16v.5"/>',
  lock: '<path d="M12 3 5 6v5c0 4.5 3 8 7 10 4-2 7-5.5 7-10V6Z"/><path d="m9.5 12 2 2 3.5-4"/>',
  play: '<path d="M8 5.5v13l10-6.5Z"/>',
  image: '<rect x="3.5" y="5" width="17" height="14" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="m4 17 5-4.5 4 3.5 3-2.5 4 3.5"/>',
  video: '<rect x="3.5" y="6" width="12" height="12" rx="2"/><path d="m15.5 10.5 5-3v9l-5-3Z"/>',
  audio: '<path d="M4 10v4M8 7v10M12 4v16M16 8v8M20 11v2"/>',
  pdf: '<path d="M6 3.5h8l4 4V20a.5.5 0 0 1-.5.5h-11A.5.5 0 0 1 6 20Z"/><path d="M14 3.5v4h4M9 12h6M9 15.5h6"/>',
  subtitle: '<rect x="3.5" y="5.5" width="17" height="13" rx="2"/><path d="M7 14h4M13 14h4M7 10.5h10"/>',
  file: '<path d="M6 3.5h8l4 4V20a.5.5 0 0 1-.5.5h-11A.5.5 0 0 1 6 20Z"/><path d="M14 3.5v4h4"/>',
  convert: '<path d="M4 9a8 8 0 0 1 14-3l2 2M20 15a8 8 0 0 1-14 3l-2-2"/><path d="M20 4v4h-4M4 20v-4h4"/>',
  compress: '<path d="M14 10l6-6M10 14l-6 6M15 4v5h5M9 20v-5H4"/>',
  resize: '<path d="M4 10V4h6M20 14v6h-6M4 4l7 7M20 20l-7-7"/>',
  stripMetadata: '<path d="M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6Z"/><circle cx="12" cy="12" r="2.5"/><path d="M4 4l16 16"/>',
  extractAudio: '<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>',
  trim: '<circle cx="6" cy="7" r="2.5"/><circle cx="6" cy="17" r="2.5"/><path d="M8 8.5 20 17M8 15.5 20 7"/>',
  videoFrame: '<rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M8 5v14M16 5v14"/>',
  imagesToPdf: '<rect x="6" y="3.5" width="13" height="13" rx="2"/><path d="M4 7.5v11A2 2 0 0 0 6 20.5h11"/>',
  mergePdf: '<rect x="4" y="4" width="10" height="13" rx="1.5"/><rect x="10" y="7" width="10" height="13" rx="1.5"/>',
  splitPdf: '<rect x="4" y="4" width="7" height="16" rx="1.5"/><rect x="13" y="4" width="7" height="16" rx="1.5"/>',
  extractText: '<path d="M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16M8 9h8M12 9v7"/>',
  zip: '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M12 4v2M12 8v2M12 12v2"/><rect x="10.5" y="14" width="3" height="3" rx=".5"/>',
  text: '<path d="M5 6h14M5 10h14M5 14h10M5 18h7"/>',
  copyPath: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  reveal: '<path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v2"/><path d="M3.5 7.5v9a2 2 0 0 0 2 2h4"/><circle cx="16" cy="16" r="3"/><path d="m18.2 18.2 2.3 2.3"/>',
  openFolder: '<path d="M3.5 18.5V7.5a2 2 0 0 1 2-2h4l2 2h6a2 2 0 0 1 2 2v1.5"/><path d="M3.5 18.5 6 12h15l-2.5 6.5Z"/>',
};
const KIND_ICON = { image: "image", video: "video", audio: "audio", pdf: "pdf", subtitle: "subtitle", folder: "folder" };

const TOOLS = {
  convert: ["تحويل الصيغة", "Convert format", "صور وفيديو وصوت وPDF وترجمة إلى صيغة أخرى.", "Images, video, audio, PDF and subtitles to another format."],
  compress: ["ضغط الملف", "Compress", "حجم أصغر للصور والفيديو والصوت.", "Smaller images, video and audio."],
  resize: ["تغيير المقاس", "Resize image", "الضلع الأطول بالبكسل، دون تكبير.", "Longest side in pixels, never upscales."],
  stripMetadata: ["تنظيف البيانات", "Clean metadata", "حذف Metadata مع الحفاظ على الأصل.", "Remove metadata, keep the original."],
  extractAudio: ["استخراج الصوت", "Extract audio", "مسار الصوت من الفيديو إلى MP3 أو M4A أو WAV.", "Video soundtrack to MP3, M4A or WAV."],
  trim: ["قص المدة", "Trim media", "جزء من الفيديو أو الصوت بالثواني.", "A section of video or audio, in seconds."],
  videoFrame: ["لقطة من الفيديو", "Video snapshot", "إطار PNG من ثانية محددة.", "A PNG frame at a chosen second."],
  imagesToPdf: ["صور إلى PDF", "Images to PDF", "صفحة لكل صورة بالترتيب.", "One page per image, in order."],
  mergePdf: ["دمج PDF", "Merge PDFs", "ملفات PDF في مستند واحد بالترتيب.", "PDFs into one document, in order."],
  splitPdf: ["تقسيم PDF", "Split PDF", "ملف لكل صفحة.", "One file per page."],
  extractText: ["استخراج النص · OCR", "Extract text · OCR", "نص PDF، ثم OCR من Windows للصفحات والصور المصورة.", "PDF text, then Windows OCR for scanned pages and images."],
  zip: ["إنشاء ZIP", "Create ZIP", "أرشيف للملفات والمجلدات.", "Archive files and folders."],
};
/** Tiny element builder. Strings become text nodes (never HTML). */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === false || v == null) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}
function icon(name) {
  const span = h("span", { class: "ico", "aria-hidden": "true" });
  span.innerHTML = `<svg viewBox="0 0 24 24">${ICONS[name] || ICONS.file}</svg>`; // constant markup only
  return span;
}
/** dark | light from the saved theme (system follows Windows). */
function resolveTheme(theme) {
  return theme === "system" ? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark") : theme;
}
