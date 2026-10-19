"use strict";
// Zawiya Tools (Windows) UI. Plain DOM; untrusted text (file names, banner) only via textContent.

const TOOL_ORDER = Object.keys(TOOLS);
const NEEDS_FORMAT = new Set(["convert", "extractAudio"]);
const SIZES = [800, 1200, 1600, 1920, 2560, 3840];

const S = {
  info: null,
  settings: { language: "ar", theme: "dark", autoUpdate: true, outputDir: null, dismissedBanner: null },
  section: "workspace",
  items: [],
  tool: "convert",
  options: { format: "png", quality: 80, maxDimension: 1920, start: 0, duration: 10 },
  running: false,
  jobId: null,
  cancelled: false,
  banner: null,
  updateVersion: null,
  updateStatus: "",
  dropTarget: false,
  wheel: { hotkeyActive: false, contextMenu: false },
  recording: false,
  hotkeyError: "",
};
let nextId = 1;

const ar = () => S.settings.language === "ar";
const t = (a, e) => (ar() ? a : e);
const $ = (id) => document.getElementById(id);

function fillIcons(root = document) {
  root.querySelectorAll("[data-icon]").forEach((el) => el.replaceWith(icon(el.dataset.icon)));
}
function bytes(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** i).toFixed(i ? 1 : 0)} ${u[i]}`;
}
function say(text) { $("live").textContent = text; }
function errorText(e) { return typeof e === "string" ? e : (e && e.message) || String(e); }

// ---------- derived state (port of MenuCatalog / Workspace) ----------
const pending = () => S.items.filter((i) => ["ready", "failed", "cancelled"].includes(i.state));
const completed = () => S.items.filter((i) => i.state === "done").length;
const menuKinds = () => [...new Set((pending().length ? pending() : S.items).map((i) => i.kind))];
const toolInfo = (id) => S.info.tools.find((x) => x.id === id);
const accepts = (tool, kind) => toolInfo(tool).accepts.includes(kind);

function commonFormats(kinds) {
  if (!kinds.length) return S.info.formats.image || [];
  const lists = kinds.map((k) => S.info.formats[k] || []);
  return lists[0].filter((f) => lists.every((l) => l.includes(f)));
}
function formatsFor(tool) {
  const kinds = menuKinds();
  if (tool === "extractAudio") return (S.info.formats.video || []).filter((f) => ["mp3", "m4a", "wav"].includes(f));
  if (tool === "compress") return kinds.length && kinds.every((k) => k === "image") ? commonFormats(kinds) : [];
  return commonFormats(kinds);
}
const showsFormat = (tool) => NEEDS_FORMAT.has(tool) || (tool === "compress" && formatsFor("compress").length > 0);
function compatibleTools() {
  const kinds = menuKinds();
  return TOOL_ORDER.filter((tool) => kinds.every((k) => accepts(tool, k)) && (tool !== "convert" || !kinds.length || commonFormats(kinds).length));
}
function normalizeFormat() {
  const list = formatsFor(S.tool);
  if (list.length && !list.includes(S.options.format)) S.options.format = list[0];
}
function canRun() {
  if (S.running || !pending().length || !compatibleTools().includes(S.tool)) return false;
  return !showsFormat(S.tool) || formatsFor(S.tool).includes(S.options.format);
}

// ---------- actions ----------
async function addPaths(paths) {
  if (S.running || !paths || !paths.length) return;
  const entries = await invoke("inspect", { paths });
  for (const e of entries) {
    if (S.items.length >= 2000 || S.items.some((i) => i.path === e.path)) continue;
    S.items.push({ ...e, id: nextId++, state: "ready", outputs: [], outBytes: 0, detail: "", seconds: 0 });
  }
  if (!compatibleTools().includes(S.tool) && compatibleTools().length) S.tool = compatibleTools()[0];
  S.section = "workspace";
  normalizeFormat();
  render();
}
const chooseFiles = async () => addPaths(await invoke("pick_files"));
const chooseFolder = async () => addPaths(await invoke("pick_folder"));
async function chooseOutput() {
  const [dir] = await invoke("pick_folder");
  if (dir) await saveSettings({ outputDir: dir });
}
function selectTool(id) {
  if (S.running) return;
  S.tool = id;
  normalizeFormat();
  S.section = "workspace";
  render();
}
function removeItem(id) { if (!S.running) { S.items = S.items.filter((i) => i.id !== id); normalizeFormat(); render(); } }
function clearItems() { if (!S.running) { S.items = []; render(); } }
function requeue() {
  if (S.running) return;
  S.items.forEach((i) => Object.assign(i, { state: "ready", detail: "", outBytes: 0, seconds: 0 }));
  render();
}
async function reveal(path) { if (path) await invoke("reveal", { path }).catch((e) => say(errorText(e))); }
async function openLink(url) { await invoke("open_link", { url }).catch(() => {}); }

async function start() {
  if (!canRun()) return;
  const entries = pending();
  const groups = toolInfo(S.tool).grouped ? [entries] : entries.map((e) => [e]);
  const tool = S.tool;
  const options = {
    format: S.options.format,
    quality: Math.round(Math.min(100, Math.max(1, S.options.quality))),
    maxDimension: S.options.maxDimension,
    start: Math.min(604800, Math.max(0, Number(S.options.start) || 0)),
    duration: Math.min(604800, Math.max(0.1, Number(S.options.duration) || 10)),
  };
  S.running = true;
  S.cancelled = false;
  render();
  for (const group of groups) {
    if (S.cancelled) break;
    const jobId = `job-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    S.jobId = jobId;
    group.forEach((g) => Object.assign(g, { state: "running", detail: "", outputs: [] }));
    render();
    const started = performance.now();
    try {
      const res = await invoke("run_job", { jobId, tool, inputs: group.map((g) => g.path), options, outputDir: S.settings.outputDir });
      group.forEach((g) => Object.assign(g, { state: "done", outputs: res.outputs, outBytes: group.length === 1 ? res.bytes : 0, seconds: (performance.now() - started) / 1000 }));
    } catch (e) {
      group.forEach((g) => Object.assign(g, { state: S.cancelled ? "cancelled" : "failed", detail: errorText(e) }));
    }
    render();
  }
  S.running = false;
  S.jobId = null;
  render();
  say(t(`${completed()} من ${S.items.length} مكتمل`, `${completed()} of ${S.items.length} completed`));
}
async function cancel() {
  S.cancelled = true;
  if (S.jobId) await invoke("cancel_job", { jobId: S.jobId });
}

async function saveSettings(patch) {
  S.settings = await invoke("save_settings", { settings: { ...S.settings, ...patch } });
  S.wheel = await invoke("wheel_status");
  applyTheme();
  render();
}
/** Files sent from the quick wheel for a tool that needs settings (quality, size, time). */
async function loadFromWheel({ paths, tool }) {
  if (S.running) return say(t("انتظر انتهاء العملية الحالية", "Wait for the current job to finish"));
  S.items = [];
  await addPaths(paths);
  if (compatibleTools().includes(tool)) selectTool(tool);
}

// ---------- hotkey recorder ----------
const MODIFIER_CODES = /^(Control|Shift|Alt|Meta|OS)(Left|Right)?$/;
function hotkeyFrom(e) {
  if (MODIFIER_CODES.test(e.code)) return null;
  const key = e.code.replace(/^Key([A-Z])$/, "$1").replace(/^Digit(\d)$/, "$1");
  return [e.ctrlKey && "Ctrl", e.altKey && "Alt", e.shiftKey && "Shift", e.metaKey && "Win", key].filter(Boolean).join("+");
}
function onRecordKey(e) {
  if (!S.recording) return;
  e.preventDefault();
  e.stopPropagation();
  if (e.key === "Escape") { S.recording = false; return render(); }
  const combo = hotkeyFrom(e);
  if (!combo) return;
  S.recording = false;
  saveSettings({ hotkey: combo }).then(() => { S.hotkeyError = ""; }, (err) => { S.hotkeyError = errorText(err); render(); });
}
async function loadBanner() {
  S.banner = await invoke("get_banner").catch(() => null);
  renderBanner();
}
async function checkUpdates() {
  S.updateStatus = t("جارٍ التحقق…", "Checking…");
  render();
  try {
    const r = await invoke("check_for_updates");
    S.updateStatus = r === "ready" ? t("التحديث جاهز", "Update ready") : r === "busy" ? t("جارٍ التنزيل…", "Downloading…") : t("لديك أحدث إصدار", "You're up to date");
  } catch (e) {
    S.updateStatus = t("تعذر التحقق من التحديثات", "Couldn't check for updates") + " · " + errorText(e).slice(0, 120);
  }
  render();
}

// ---------- rendering ----------
function applyTheme() {
  document.documentElement.dataset.theme = resolveTheme(S.settings.theme);
  document.documentElement.lang = S.settings.language;
  document.documentElement.dir = ar() ? "rtl" : "ltr";
}

const SECTIONS = [
  ["workspace", "مساحة العمل", "Workspace"],
  ["tools", "كل الأدوات", "All tools"],
  ["settings", "الإعدادات", "Settings"],
  ["about", "حول", "About"],
];

function renderChrome() {
  const nav = $("nav");
  nav.replaceChildren(...SECTIONS.map(([id, a, e]) => h("button", { class: "nav-item", type: "button", "aria-current": S.section === id ? "page" : null, onclick: () => { S.section = id; render(); $("content").focus(); } }, icon(id), h("span", {}, t(a, e)))));
  const [, a, e] = SECTIONS.find((s) => s[0] === S.section);
  $("title").textContent = t(a, e);
  $("subtitle").textContent = t("أداة زاوية · أحمد مروان", "File utilities · Ahmed Marwan");
  $("search-label").textContent = t("الأدوات", "Tools");
  $("search-btn").setAttribute("aria-label", t("البحث في كل الأدوات", "Search all tools"));
  $("lang-btn").textContent = ar() ? "EN" : "ع";
  $("lang-btn").setAttribute("aria-label", t("التبديل إلى الإنجليزية", "Switch to Arabic"));
  $("theme-btn").setAttribute("aria-label", t("تبديل المظهر", "Toggle appearance"));
  $("local-note").textContent = t("معالجة محلية على جهازك", "Processed on your PC");
  $("oss-link").textContent = t("مفتوح المصدر GPL-3.0", "Open source GPL-3.0");
  $("version").textContent = `v${S.info.version}`;
  $("search-close").textContent = t("إغلاق", "Close");
  $("search-input").placeholder = t("ابحث عن أداة أو صيغة…", "Find a tool or format…");
  $("search-foot").textContent = t("الأدوات غير المتوافقة ظاهرة لتعرف ما تحتاجه. Ctrl K / Esc", "Unavailable tools stay visible so you can see what they need. Ctrl K / Esc");
  const bar = $("update-bar");
  bar.hidden = !S.updateVersion;
  if (S.updateVersion) {
    bar.replaceChildren(icon("check"), h("span", {}, t(`التحديث ${S.updateVersion} جاهز`, `Update ${S.updateVersion} ready`)),
      h("button", { class: "primary", type: "button", disabled: S.running, onclick: () => invoke("restart_to_update").catch((e) => say(errorText(e))) }, t("إعادة التشغيل", "Restart")));
  }
}

function renderBanner() {
  const box = $("banner");
  const b = S.banner;
  box.hidden = !b;
  if (!b) return box.replaceChildren();
  const card = h("div", { class: "banner", role: "complementary", "aria-label": t("إعلان", "Announcement") },
    h("button", { class: "close", type: "button", "aria-label": t("إغلاق الإعلان", "Dismiss announcement"), onclick: async () => { await invoke("dismiss_banner", { id: b.id }); S.settings.dismissedBanner = b.id; S.banner = null; renderBanner(); } }, icon("close")),
    b.imageData ? h("img", { src: b.imageData, alt: "", referrerpolicy: "no-referrer" }) : null,
    h("div", { class: "banner-title" }, t(b.titleAr, b.titleEn)),
    t(b.bodyAr, b.bodyEn) ? h("div", { class: "banner-body" }, t(b.bodyAr, b.bodyEn)) : null,
    t(b.ctaAr, b.ctaEn) ? h("button", { class: "secondary cta", type: "button", onclick: () => openLink(b.url) }, t(b.ctaAr, b.ctaEn)) : null);
  box.replaceChildren(card);
}

function dropZone() {
  const empty = !S.items.length;
  const zone = empty
    ? h("div", { class: "drop empty" + (S.dropTarget ? " target" : "") },
        h("span", { class: "big-ico" }, icon("drop")),
        h("h2", {}, t("أفلت ملفاتك هنا", "Drop your files here")),
        h("div", { class: "muted small" }, t("صور، فيديو، صوت، PDF وترجمة", "Images, video, audio, PDF and subtitles")),
        h("div", { class: "row-actions" },
          h("button", { class: "primary", type: "button", disabled: S.running, onclick: chooseFiles }, icon("plus"), t("اختيار ملفات", "Choose files")),
          h("button", { class: "secondary", type: "button", disabled: S.running, onclick: chooseFolder }, t("مجلد…", "Folder…"))),
        h("div", { class: "muted small" }, t("الأصول تبقى محفوظة. النتائج في مجلد مستقل.", "Originals stay safe. Results go into a separate folder.")))
    : h("div", { class: "drop compact" + (S.dropTarget ? " target" : "") },
        h("span", { class: "ok-text" }, icon("plus")),
        h("span", { class: "spacer" }, t("أفلت ملفات إضافية", "Drop more files")),
        h("button", { class: "link", type: "button", disabled: S.running, onclick: chooseFiles }, t("اختيار…", "Browse…")),
        h("button", { class: "link", type: "button", disabled: S.running, onclick: chooseFolder }, t("مجلد…", "Folder…")));
  return zone;
}

function fileRow(item) {
  const sizes = [bytes(item.bytes)];
  if (item.outBytes) sizes.push("→", bytes(item.outBytes));
  if (item.state === "done") sizes.push(`${item.seconds.toFixed(1)}s`);
  let status = null;
  if (item.state === "running") status = h("div", { class: "spinner", role: "progressbar", "aria-label": t("جارٍ المعالجة", "Processing") });
  else if (item.state === "done") status = h("button", { class: "icon-btn ok", type: "button", title: t("إظهار في المستكشف", "Show in Explorer"), "aria-label": t("إظهار في المستكشف", "Show in Explorer"), onclick: () => reveal(item.outputs[0]) }, icon("check"));
  else if (item.state === "failed" || item.state === "cancelled") status = h("span", { class: "warn", title: item.detail }, icon("alert"));
  return h("div", { class: "file" },
    h("div", { class: "kind" }, icon(KIND_ICON[item.kind] || "file")),
    h("div", { class: "meta" },
      h("div", { class: "name", title: item.path }, item.name),
      h("div", { class: "sizes" }, sizes.join("  ")),
      item.detail ? h("div", { class: "detail" }, item.detail) : null),
    status,
    S.running ? null : h("button", { class: "icon-btn", type: "button", "aria-label": t("إزالة من القائمة", "Remove from queue"), onclick: () => removeItem(item.id) }, icon("close")));
}

function filesPanel() {
  const outputs = [...new Set(S.items.flatMap((i) => i.outputs))];
  return h("div", { class: "panel" },
    h("div", { class: "files-head" },
      h("h3", {}, t(`الملفات · ${S.items.length}`, `Files · ${S.items.length}`)),
      h("span", { class: "muted small", dir: "ltr" }, bytes(S.items.reduce((s, i) => s + i.bytes, 0))),
      completed() && !pending().length ? h("button", { class: "link", type: "button", disabled: S.running, onclick: requeue }, t("تكرار الدفعة", "Repeat batch")) : null,
      h("button", { class: "link muted", type: "button", disabled: S.running, onclick: clearItems }, t("إفراغ", "Clear"))),
    outputs.length && !S.running
      ? h("div", { class: "ready" }, icon("check"), h("span", {}, pending().length ? t("نتائج سابقة متاحة", "Previous results available") : t("ملفاتك جاهزة", "Your files are ready")),
          h("button", { class: "link", type: "button", onclick: () => reveal(outputs[0]) }, t("إظهار في المستكشف", "Show in Explorer")))
      : null,
    S.items.map(fileRow));
}

function controls() {
  const kinds = menuKinds();
  const compatible = compatibleTools();
  const disabled = S.running;
  const o = S.options;
  const panel = h("div", { class: "panel" }, h("h3", {}, t("إعداد العملية", "Job settings")));
  const toolSel = h("select", { id: "tool-select", disabled, onchange: (e) => selectTool(e.target.value) },
    TOOL_ORDER.map((id) => h("option", { value: id, selected: S.tool === id, disabled: !compatible.includes(id) }, t(TOOLS[id][0], TOOLS[id][1]))));
  panel.append(h("div", { class: "field" }, h("label", { for: "tool-select" }, t("الأداة", "Tool")), toolSel));
  if (pending().length && !compatible.includes(S.tool)) {
    panel.append(h("p", { class: "warn" }, t("الأداة المحددة لا تناسب هذه الدفعة. اختر أداة متاحة أو افصل أنواع الملفات.", "This tool cannot process this batch. Choose an available tool or split the file types.")));
  }
  if (showsFormat(S.tool)) {
    const list = formatsFor(S.tool);
    panel.append(h("div", { class: "field" }, h("label", { for: "format-select" }, t("الصيغة", "Format")),
      h("select", { id: "format-select", disabled: disabled || !list.length, onchange: (e) => { S.options.format = e.target.value; render(); } },
        list.length ? list.map((f) => h("option", { value: f, selected: o.format === f }, f.toUpperCase())) : h("option", {}, t("لا توجد صيغة مشتركة", "No shared format")))));
    if (!list.length && kinds.length) panel.append(h("p", { class: "warn" }, t("هذه الأنواع لا تشترك بصيغة واحدة. افصل الدفعات حسب النوع.", "These file types have no shared format. Use separate batches.")));
  }
  const lossy = S.tool === "compress" || S.tool === "resize" || (S.tool === "convert" && kinds.some((k) => ["image", "video", "audio", "pdf"].includes(k)));
  if (lossy) {
    const value = h("b", {}, `${o.quality}%`);
    panel.append(h("div", { class: "field" },
      h("div", { class: "range-head" }, h("label", { for: "quality" }, t("جودة الصيغ المضغوطة", "Lossy quality")), value),
      h("input", { id: "quality", type: "range", min: 10, max: 100, step: 1, value: o.quality, disabled, oninput: (e) => { o.quality = Number(e.target.value); value.textContent = `${o.quality}%`; } }),
      h("p", { class: "hint" }, t("لا تغيّر جودة صيغ Lossless وGIF وWMA.", "Lossless formats, GIF and WMA keep their quality."))));
  }
  if (S.tool === "resize" || (S.tool === "convert" && kinds.includes("pdf"))) {
    panel.append(h("div", { class: "field" }, h("label", { for: "size" }, t("الضلع الأطول · px", "Longest edge · px")),
      h("select", { id: "size", disabled, onchange: (e) => { o.maxDimension = Number(e.target.value); } }, SIZES.map((s) => h("option", { value: s, selected: o.maxDimension === s }, `${s} px`))),
      h("p", { class: "hint" }, t("المقاس يطبق على تغيير مقاس الصور وتصدير صفحات PDF فقط.", "Size applies to image resizing and PDF page exports only."))));
  }
  if (S.tool === "trim" || S.tool === "videoFrame") {
    const num = (id, key, label, min) => h("div", { class: "field" }, h("label", { for: id }, label),
      h("input", { id, type: "number", min, max: 604800, step: "0.1", value: o[key], disabled, dir: "ltr", onchange: (e) => { o[key] = Number(e.target.value); } }));
    panel.append(num("start", "start", t("البداية بالثواني", "Start in seconds"), 0));
    if (S.tool === "trim") panel.append(num("duration", "duration", t("المدة بالثواني", "Duration in seconds"), 0.1));
  }
  if (S.tool === "extractText") {
    const langs = S.info.ocrLanguages;
    panel.append(h("p", { class: "hint" }, langs.length
      ? t(`OCR محلي من Windows. اللغات المثبتة: ${langs.join("، ")}`, `Local Windows OCR. Installed languages: ${langs.join(", ")}`)
      : t("OCR غير متاح: ثبّت لغة OCR من إعدادات Windows ← الوقت واللغة. نص PDF المضمّن يعمل دونه.", "OCR unavailable: add an OCR language in Windows Settings → Time & language. Embedded PDF text still works.")));
  }
  panel.append(h("div", { class: "divider" }),
    h("div", { class: "field" }, h("span", { class: "label" }, t("حفظ النتائج", "SAVE RESULTS")),
      h("div", { class: "out-path" }, S.settings.outputDir || t("Zawiya Exports بجوار أول ملف", "Zawiya Exports beside the first file")),
      h("div", { class: "out-actions" },
        h("button", { class: "link", type: "button", disabled, onclick: chooseOutput }, t("تغيير المجلد…", "Change folder…")),
        S.settings.outputDir ? h("button", { class: "link muted", type: "button", disabled, onclick: () => saveSettings({ outputDir: null }) }, t("الافتراضي", "Default")) : null)),
    h("p", { class: "hint" }, t("يتم إنشاء نسخ جديدة دائمًا. قد يختلف حجم الضغط حسب المحتوى.", "Always creates new copies. Compression savings depend on the content.")));
  return panel;
}

function workspacePage() {
  if (!S.items.length) return h("div", { class: "workspace" }, h("div", { class: "stack" }, dropZone()), controls());
  return h("div", { class: "workspace" }, h("div", { class: "stack" }, dropZone(), filesPanel()), controls());
}

function toolButton(id, onPick) {
  const ok = compatibleTools().includes(id);
  const note = !ok ? t("تحتاج نوع ملفات مختلفًا", "Needs a different file type") : pending().length ? t("متاحة للملفات الحالية", "Available for the current files") : t(TOOLS[id][2], TOOLS[id][3]);
  return h("button", { class: "tool-row" + (S.tool === id ? " active" : ""), type: "button", role: "option", disabled: !ok || S.running, onclick: () => onPick(id) },
    icon(id), h("span", { class: "txt" }, h("b", {}, t(TOOLS[id][0], TOOLS[id][1])), h("span", { class: "muted small" }, note)),
    S.tool === id ? h("span", { class: "ok-text" }, icon("check")) : null);
}

function toolsPage() {
  const kindNames = { image: t("صور", "Images"), video: t("فيديو", "Video"), audio: t("صوت", "Audio"), pdf: "PDF", subtitle: t("ترجمة", "Subtitles") };
  return h("div", { class: "page" },
    h("div", { class: "page-title" }, h("h2", {}, t("كل الأدوات", "All tools")), h("p", {}, t("اختر أداة ثم أضف ملفاتك. الأدوات غير المتوافقة تظهر معطلة.", "Pick a tool, then add files. Incompatible tools are shown disabled."))),
    h("div", { class: "panel" }, TOOL_ORDER.map((id) => toolButton(id, selectTool))),
    h("div", { class: "panel" }, h("h3", {}, t("الصيغ المتاحة", "Available formats")),
      h("dl", { class: "kv" }, Object.entries(kindNames).flatMap(([k, name]) => [h("dt", {}, name), h("dd", { dir: "ltr" }, (S.info.formats[k] || []).map((f) => f.toUpperCase()).join("  ·  ") || "—")]))),
    h("div", { class: "panel" }, h("h3", {}, t("المحركات", "Engines")),
      h("dl", { class: "kv" },
        h("dt", {}, "FFmpeg"), h("dd", { class: S.info.ffmpeg ? "ok-text" : "warn" }, S.info.ffmpeg ? t("متاح", "Available") : t("غير موجود", "Missing")),
        h("dt", {}, "PDFium"), h("dd", { class: S.info.pdfium ? "ok-text" : "warn" }, S.info.pdfium ? t("متاح", "Available") : t("غير موجود", "Missing")),
        h("dt", {}, "OCR"), h("dd", { dir: "ltr" }, S.info.ocrLanguages.join(", ") || t("غير متاح", "Unavailable")))),
    h("div", { class: "panel" }, h("h3", {}, t("لم تُنفذ بعد", "Not implemented yet")),
      h("p", { class: "hint" }, t("Office وEPUB · PDF إلى Word · فك الأرشيف · تحرير الصور والحجب · HEIC/AVIF export · وصفات متسلسلة ومجلدات مراقبة.", "Office and EPUB · PDF to Word · archive extraction · image editing and redaction · HEIC/AVIF export · multi-step recipes and watched folders."))));
}

function wheelPanel() {
  const st = S.settings;
  const sw = (key, label) => h("label", { class: "setting" }, h("span", {}, label),
    h("input", { class: "switch", type: "checkbox", role: "switch", checked: st[key], onchange: (e) => saveSettings({ [key]: e.target.checked }) }));
  const hotkeyHint = !st.hotkeyEnabled ? null
    : S.wheel.hotkeyActive ? h("p", { class: "hint" }, t(`حدد ملفات في المستكشف أو على سطح المكتب ثم اضغط ${st.hotkey} لتظهر العجلة عند المؤشر.`, `Select files in Explorer or on the desktop, then press ${st.hotkey} to open the wheel at the pointer.`))
    : h("p", { class: "warn" }, t("الاختصار محجوز من تطبيق آخر. سجّل اختصاراً مختلفاً.", "Another app already uses this shortcut. Record a different one."));
  return h("div", { class: "panel" }, h("h3", {}, t("العجلة السريعة", "Quick wheel")),
    h("p", { class: "hint" }, t("عجلة تحويل وأدوات وإجراءات تعمل في الخلفية، والنتائج في Zawiya Exports. الأدوات التي تحتاج إعداداً تفتح هذه النافذة.", "A convert, tools and actions wheel that works in the background; results go to Zawiya Exports. Tools that need settings open this window.")),
    sw("keepInTray", t("إبقاء الأداة في شريط المهام عند الإغلاق", "Keep running in the tray when closed")),
    h("p", { class: "hint" }, st.keepInTray
      ? t("إغلاق النافذة يخفيها في شريط المهام لتبقى العجلة تعمل. للخروج: أيقونة زاوية ← إنهاء.", "Closing the window hides it in the tray so the wheel keeps working. To quit: Zawiya tray icon → Quit.")
      : t("إغلاق النافذة ينهي الأداة، فيتوقف الاختصار والفقاعة.", "Closing the window quits, which stops the shortcut and the bubble.")),
    h("div", { class: "divider" }),
    sw("hotkeyEnabled", t("اختصار لوحة المفاتيح", "Keyboard shortcut")),
    h("div", { class: "setting" }, h("span", {}, t("الاختصار", "Shortcut")),
      h("span", { class: "links" }, h("kbd", { class: "hotkey", dir: "ltr" }, S.recording ? t("اضغط الاختصار… Esc للإلغاء", "Press the shortcut… Esc to cancel") : st.hotkey),
        h("button", { class: "secondary", type: "button", disabled: S.recording, onclick: () => { S.recording = true; S.hotkeyError = ""; render(); } }, t("تسجيل…", "Record…")))),
    S.hotkeyError ? h("p", { class: "warn" }, S.hotkeyError) : hotkeyHint,
    h("div", { class: "divider" }),
    sw("bubble", t("فقاعة الإفلات العائمة", "Floating drop bubble")),
    h("p", { class: "hint" }, t("أفلت ملفات على الفقاعة لتظهر العجلة. مع Shift للتحويل، Ctrl للأدوات، Alt للإجراءات.", "Drop files on the bubble to open the wheel. Hold Shift for convert, Ctrl for tools, Alt for actions.")),
    h("div", { class: "divider" }),
    h("div", { class: "setting" }, h("span", {}, t("قائمة الزر الأيمن في المستكشف", "Explorer right-click menu")),
      h("span", { class: S.wheel.contextMenu ? "ok-text small" : "muted small" }, S.wheel.contextMenu ? t("مفعّلة: «أداة زاوية…»", "On: “أداة زاوية…”") : t("غير مثبتة", "Not installed"))),
    h("p", { class: "hint" }, S.wheel.contextMenu
      ? t("انقر بالزر الأيمن على ملف أو مجلد ← «أداة زاوية…». في Windows 11 تجدها تحت «عرض خيارات إضافية».", "Right-click a file or folder → “أداة زاوية…”. On Windows 11 it is under “Show more options”.")
      : t("يضيفها المثبّت لحسابك فقط دون صلاحيات مدير، ويحذفها عند إلغاء التثبيت.", "The installer adds it for your account only, without admin rights, and removes it on uninstall.")));
}

function settingsPage() {
  const seg = (key, options) => h("div", { class: "seg", role: "group" }, options.map(([v, a, e]) =>
    h("button", { type: "button", "aria-pressed": String(S.settings[key] === v), onclick: () => saveSettings({ [key]: v }) }, t(a, e))));
  return h("div", { class: "page" },
    h("div", { class: "page-title" }, h("h2", {}, t("التفضيلات", "Preferences")), h("p", {}, t("المظهر واللغة والعجلة السريعة والتحديثات.", "Appearance, language, quick wheel and updates."))),
    h("div", { class: "panel" },
      h("div", { class: "setting" }, h("span", {}, t("المظهر", "Appearance")), seg("theme", [["dark", "داكن", "Dark"], ["light", "فاتح", "Light"], ["system", "حسب النظام", "System"]])),
      h("div", { class: "setting" }, h("span", {}, t("اللغة", "Language")), seg("language", [["ar", "العربية", "العربية"], ["en", "English", "English"]]))),
    wheelPanel(),
    h("div", { class: "panel" }, h("h3", {}, t("التحديثات", "Updates")),
      h("label", { class: "setting" }, h("span", {}, t("تحديثات تلقائية", "Automatic updates")),
        h("input", { class: "switch", type: "checkbox", role: "switch", checked: S.settings.autoUpdate, onchange: (e) => saveSettings({ autoUpdate: e.target.checked }) })),
      h("p", { class: "hint" }, t("يُنزّل التحديث في الخلفية ويُثبّت عند إعادة التشغيل. التحديثات موقعة ويتحقق منها التطبيق.", "Updates download in the background and install when you restart. Updates are signed and verified.")),
      h("div", { class: "setting" }, h("button", { class: "secondary", type: "button", onclick: checkUpdates }, t("التحقق من التحديثات", "Check for updates")), h("span", { class: "muted small" }, S.updateStatus))),
    h("div", { class: "panel" }, h("h3", {}, t("حفظ النتائج", "Output folder")),
      h("div", { class: "out-path" }, S.settings.outputDir || t("Zawiya Exports بجوار أول ملف", "Zawiya Exports beside the first file")),
      h("div", { class: "out-actions" }, h("button", { class: "link", type: "button", onclick: chooseOutput }, t("تغيير المجلد…", "Change folder…")),
        S.settings.outputDir ? h("button", { class: "link muted", type: "button", onclick: () => saveSettings({ outputDir: null }) }, t("الافتراضي", "Default")) : null)),
    h("div", { class: "panel" }, h("div", { class: "mono small", dir: "ltr" }, "com.ahmedqa.zawiyatools"),
      h("p", { class: "hint" }, t("معالجة الملفات محلية. الاتصال الشبكي الوحيد: الإعلانات وفحص التحديثات، دون إرسال أي بيانات عنك.", "File processing is local. The only network use is the announcement and update checks, which send no data about you."))));
}

function aboutPage() {
  const link = (url, label) => h("a", { href: "#", dir: "ltr", onclick: (e) => { e.preventDefault(); openLink(url); } }, label);
  return h("div", { class: "page about" },
    h("div", { class: "panel about-hero" }, document.querySelector(".brand .mark").cloneNode(true),
      h("div", {}, h("h2", { dir: "ltr" }, "Zawiya Tools"), h("div", { class: "muted mono", dir: "ltr" }, `v${S.info.version} · Windows`))),
    h("div", { class: "panel" },
      h("p", {}, t("أدوات ملفات محلية: تحويل وضغط وPDF وOCR وترجمة وZIP. الأصول لا تُستبدل أبدًا.", "Local file tools: convert, compress, PDF, OCR, subtitles and ZIP. Originals are never overwritten.")),
      h("p", {}, t("العجلة السريعة على Windows: اختصار لوحة المفاتيح على ملفات المستكشف، أو فقاعة الإفلات العائمة، أو «أداة زاوية…» في قائمة الزر الأيمن.", "Quick wheel on Windows: a keyboard shortcut on the Explorer selection, a floating drop bubble, or “أداة زاوية…” in the right-click menu.")),
      h("p", {}, "© 2026 أحمد مروان · Ahmed Marwan"),
      h("p", { class: "links" }, link("https://ahmedqa.com", "ahmedqa.com"), link("https://instagram.com/qqad7", "instagram.com/qqad7")),
      h("p", {}, t("مفتوح المصدر GPL-3.0 · ", "Open source GPL-3.0 · "), link("https://github.com/ahmed1blog-dot/zawiya-tools", "github.com/ahmed1blog-dot/zawiya-tools"))),
    h("div", { class: "panel" }, h("h3", {}, t("مكونات مضمّنة", "Bundled components")),
      h("p", { class: "hint" }, t("FFmpeg (GPL) لتحويل الوسائط والصور، وPDFium (BSD/Apache) لعرض PDF ونصوصه. نصوص التراخيص داخل مجلد bin في مكان التثبيت.", "FFmpeg (GPL) for media and image conversion, and PDFium (BSD/Apache) for PDF rendering and text. License texts are in the bin folder of the install location."))));
}

function footer() {
  const done = completed();
  const total = S.items.length;
  const status = h("div", { class: "status" }, icon(S.running ? "convert" : "lock"),
    h("div", { class: "status-text" },
      h("b", {}, S.running ? t("جارٍ تجهيز الملفات…", "Processing files…") : S.section === "workspace" ? t(TOOLS[S.tool][0], TOOLS[S.tool][1]) : t("المعالجة محلية", "Entirely local")),
      h("span", { class: "muted small" }, !pending().length && !S.running ? t("الأصول محفوظة • Ctrl+K لكل الأدوات", "Originals preserved • Ctrl+K for all tools") : t(`${done} من ${total} مكتمل`, `${done} of ${total} completed`))));
  const parts = [status];
  if (S.running || (total && done)) {
    const bar = h("div", {});
    bar.style.width = `${total ? (done / total) * 100 : 0}%`;
    parts.push(h("div", { class: "progress", role: "progressbar", "aria-valuemin": 0, "aria-valuemax": total, "aria-valuenow": done }, bar));
  }
  const outputs = S.items.flatMap((i) => i.outputs);
  if (outputs.length && !S.running) parts.push(h("button", { class: "icon-btn", type: "button", title: t("إظهار في المستكشف", "Show in Explorer"), "aria-label": t("إظهار في المستكشف", "Show in Explorer"), onclick: () => reveal(outputs[0]) }, icon("folder")));
  if (S.running) parts.push(h("button", { class: "secondary", type: "button", onclick: cancel }, t("إلغاء", "Cancel")));
  else if (S.section === "workspace" && !pending().length) parts.push(h("button", { class: "primary", type: "button", title: "Ctrl+O", onclick: chooseFiles }, icon("plus"), t("إضافة ملفات", "Add files")));
  else if (S.section === "workspace") parts.push(h("button", { class: "primary", type: "button", title: "Ctrl+Enter", disabled: !canRun(), onclick: start }, icon("play"),
    S.items.some((i) => i.state === "failed" || i.state === "cancelled") ? t("إعادة المحاولة", "Retry pending") : t("تنفيذ العملية", "Run job"), h("span", { class: "mono small" }, String(pending().length))));
  $("footer").replaceChildren(...parts);
}

function render() {
  if (!S.info) return;
  renderChrome();
  renderBanner();
  const page = { workspace: workspacePage, tools: toolsPage, settings: settingsPage, about: aboutPage }[S.section]();
  $("content").replaceChildren(page);
  footer();
}

// ---------- tool search (Ctrl+K) ----------
let searchIndex = 0;
function searchMatches(q) {
  const needle = q.trim().toLowerCase();
  const tools = TOOL_ORDER.filter((id) => !needle || [id, ...TOOLS[id]].some((s) => s.toLowerCase().includes(needle)));
  const formats = needle ? formatsFor("convert").filter((f) => f.includes(needle)) : [];
  return { tools, formats };
}
function renderSearch() {
  const { tools, formats } = searchMatches($("search-input").value);
  const pick = (id) => { $("search").close(); selectTool(id); };
  const rows = tools.map((id) => toolButton(id, pick));
  formats.forEach((f) => rows.push(h("button", { class: "tool-row", type: "button", role: "option", disabled: S.running, onclick: () => { $("search").close(); S.options.format = f; selectTool("convert"); } },
    icon("convert"), h("span", { class: "txt" }, h("b", {}, f.toUpperCase()), h("span", { class: "muted small" }, t("تحويل إلى هذه الصيغة", "Convert to this format"))))));
  const enabled = rows.filter((r) => !r.disabled);
  searchIndex = Math.min(searchIndex, Math.max(0, enabled.length - 1));
  enabled.forEach((r, i) => r.setAttribute("aria-selected", String(i === searchIndex)));
  $("search-results").replaceChildren(...(rows.length ? rows : [h("p", { class: "muted" }, t("لا توجد نتيجة. جرّب PDF أو ضغط أو WebP.", "No matches. Try PDF, compress or WebP."))]));
  return enabled;
}
function openSearch() {
  const dlg = $("search");
  if (dlg.open) return dlg.close();
  $("search-input").value = "";
  searchIndex = 0;
  renderSearch();
  dlg.showModal();
  $("search-input").focus();
}

// ---------- boot ----------
async function boot() {
  fillIcons();
  const [info, settings, wheel] = await Promise.all([invoke("app_info"), invoke("get_settings"), invoke("wheel_status")]);
  S.info = info;
  S.settings = settings;
  S.wheel = wheel;
  normalizeFormat();
  applyTheme();
  render();
  loadBanner();
  matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => { applyTheme(); });
  $("lang-btn").addEventListener("click", () => saveSettings({ language: ar() ? "en" : "ar" }));
  $("theme-btn").addEventListener("click", () => saveSettings({ theme: document.documentElement.dataset.theme === "dark" ? "light" : "dark" }));
  $("search-btn").addEventListener("click", openSearch);
  $("search-close").addEventListener("click", () => $("search").close());
  $("search-input").addEventListener("input", () => { searchIndex = 0; renderSearch(); });
  $("search").addEventListener("click", (e) => { if (e.target === $("search")) $("search").close(); });
  $("search-input").addEventListener("keydown", (e) => {
    if (e.key === "Escape") { e.preventDefault(); $("search").close(); return; }
    const enabled = renderSearch();
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); searchIndex = (searchIndex + (e.key === "ArrowDown" ? 1 : -1) + enabled.length) % Math.max(1, enabled.length); renderSearch(); }
    if (e.key === "Enter" && enabled[searchIndex]) { e.preventDefault(); enabled[searchIndex].click(); }
  });
  document.querySelectorAll("[data-link]").forEach((a) => a.addEventListener("click", (e) => { e.preventDefault(); openLink(a.dataset.link); }));
  document.addEventListener("keydown", onRecordKey, true);
  document.addEventListener("keydown", (e) => {
    if (!e.ctrlKey) return;
    const k = e.key.toLowerCase();
    if (k === "k") { e.preventDefault(); openSearch(); }
    else if (k === "enter") { e.preventDefault(); if (S.section === "workspace") start(); }
    else if (k === "o") { e.preventDefault(); chooseFiles(); }
  });
  // Block the webview's default file navigation on drop; Tauri delivers real paths via events.
  ["dragover", "drop"].forEach((ev) => window.addEventListener(ev, (e) => e.preventDefault()));
  const setTarget = (on) => { if (S.dropTarget !== on) { S.dropTarget = on; document.querySelectorAll(".drop").forEach((d) => d.classList.toggle("target", on)); } };
  // Scoped to this window: drops on the quick wheel bubble must not land in this queue.
  tauri.webviewWindow.getCurrentWebviewWindow().onDragDropEvent((e) => {
    const { type, paths } = e.payload;
    setTarget(type === "enter" || type === "over");
    if (type === "drop") addPaths(paths);
  });
  listen("banner-changed", loadBanner);
  listen("wheel-open-main", (e) => loadFromWheel(e.payload));
  // The tray menu toggles the bubble.
  listen("settings-changed", async () => { [S.settings, S.wheel] = await Promise.all([invoke("get_settings"), invoke("wheel_status")]); render(); });
  listen("update-ready", (e) => { S.updateVersion = e.payload; S.updateStatus = t("التحديث جاهز", "Update ready"); render(); });
}

document.addEventListener("DOMContentLoaded", () => boot().catch((e) => { document.body.textContent = `Zawiya Tools failed to start: ${errorText(e)}`; }));
