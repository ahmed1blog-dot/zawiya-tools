"use strict";
// Quick windows: the wheel, the result toast and the drop bubble share this page; the window label picks the view.
// Untrusted text (file names, errors) only via textContent.

const current = tauri.webviewWindow.getCurrentWebviewWindow();
const MARK = '<svg class="mark" viewBox="0 0 34 34" aria-hidden="true"><path d="M29 27 L7 27 L22 7"/><path d="M17 27 A10 10 0 0 0 13 19"/><circle cx="7" cy="27" r="2.8"/></svg>';
const FORMAT_KINDS = [["image", ["jpg", "png", "webp", "heic", "tiff", "bmp"]], ["video", ["mp4", "mov", "mkv", "webm", "avi", "gif"]], ["audio", ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]], ["pdf", ["pdf"]]];
const ACTION_NAMES = { copyPath: ["نسخ المسار", "Copy path"], reveal: ["إظهار في المستكشف", "Show in Explorer"], openFolder: ["فتح المجلد", "Open folder"] };
// [mode, glyph, ar title, en title, ar label, en label]; glyphs match the bubble's drop modifiers.
const MODES = [
  ["convert", "⇧", "حوّل", "Convert", "عجلة التحويل · Shift", "Conversion wheel · Shift"],
  ["tools", "Ctrl", "أدوات", "Tools", "عجلة الأدوات · Ctrl", "Tools wheel · Ctrl"],
  ["actions", "Alt", "إجراءات", "Actions", "عجلة الإجراءات · Alt", "Actions wheel · Alt"],
];

let lang = "ar";
const t = (a, e) => (lang === "ar" ? a : e);
const root = () => document.getElementById("root");
function look({ language, theme }) {
  lang = language || "ar";
  document.documentElement.lang = lang;
  document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
  document.documentElement.dataset.theme = resolveTheme(theme || "dark");
}
function mark() {
  const box = h("span");
  box.innerHTML = MARK; // constant markup only
  return box.firstChild;
}

// ---------- wheel ----------
let view = null;
let selected = -1;
let cells = [];

const formatIcon = (f) => (FORMAT_KINDS.find(([, list]) => list.includes(f)) || ["text"])[0];
function itemName(item) {
  const [a, e] = view.mode === "convert" ? [item.id.toUpperCase(), item.id.toUpperCase()] : view.mode === "tools" ? TOOLS[item.id] : ACTION_NAMES[item.id];
  return t(a, e) + (item.needsSettings ? "…" : "");
}

async function loadWheel(next) {
  view = next || (await invoke("wheel_view"));
  look(view);
  selected = -1;
  const [, , ta, te] = MODES.find((m) => m[0] === view.mode);
  cells = view.items.map((item, i) => {
    const name = itemName(item);
    const cell = h("button", { class: "cell", type: "button", role: "option", tabindex: "-1", "aria-selected": "false", "aria-label": name, onmouseenter: () => select(i), onclick: () => run(i) },
      icon(view.mode === "convert" ? formatIcon(item.id) : item.id), h("span", {}, name));
    cell.style.left = `${item.x - 34}px`;
    cell.style.top = `${item.y - 31}px`;
    return cell;
  });
  const modes = h("div", { class: "modes" }, MODES.map(([id, glyph, , , la, le], i) =>
    h("button", { type: "button", tabindex: "-1", "aria-pressed": String(view.mode === id), "aria-label": t(la, le), title: t(la, le), disabled: !view.available[i],
      onclick: () => view.mode !== id && invoke("wheel_mode", { mode: id }).then(loadWheel) }, glyph)));
  const ring = h("div", { class: "wheel", role: "listbox", "aria-label": t(ta, te) }, cells,
    cells.length ? null : h("div", { class: "empty-ring" }, t("لا توجد خيارات لهذه الملفات", "No choices for these files")),
    h("div", { class: "center" }, mark(), h("b", {}, t(ta, te)), modes));
  ring.addEventListener("mouseleave", () => select(-1));
  root().replaceChildren(ring);
}
function select(i) {
  if (i === selected) return;
  selected = i;
  cells.forEach((c, j) => c.setAttribute("aria-selected", String(j === i)));
  if (cells[i]) document.getElementById("live").textContent = cells[i].getAttribute("aria-label");
}
function step(delta) {
  if (!cells.length) return;
  select(selected < 0 ? (delta > 0 ? 0 : cells.length - 1) : (selected + delta + cells.length) % cells.length);
}
async function run(i) {
  const item = view && view.items[i];
  if (!item) return;
  if (view.mode === "actions" && item.id === "copyPath") {
    // Same format as Explorer's "Copy as path".
    const ok = await navigator.clipboard.writeText(view.paths.map((p) => `"${p}"`).join("\r\n")).then(() => true, () => false);
    if (!ok) return invoke("wheel_close");
  }
  invoke("wheel_run", { id: item.id }).catch(() => {});
}
function wheelKeys(e) {
  if (!view) return;
  const back = e.key === "ArrowLeft" || e.key === "ArrowUp" || (e.key === "Tab" && e.shiftKey);
  if (e.key === "Escape") invoke("wheel_close");
  else if (["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp", "Tab"].includes(e.key)) step(back ? -1 : 1);
  else if (e.key === "Enter" && selected >= 0) run(selected);
  else return;
  e.preventDefault();
}

// ---------- toast ----------
async function loadToast() {
  const q = await invoke("toast_state");
  look(q);
  const busy = q.state === "queued" || q.state === "running";
  const select = q.state === "info" && q.message === "select";
  const title = q.state === "info"
    ? (select ? t("حدد ملفات في المستكشف أولاً", "Select files in Explorer first") : t("نُسخ المسار", "Path copied"))
    : t(TOOLS[q.tool][0], TOOLS[q.tool][1]) + (q.tool === "convert" ? ` · ${q.format.toUpperCase()}` : "");
  const detail = {
    info: select ? t("حدد ملفاً أو أكثر في نافذة المستكشف أو على سطح المكتب، ثم اضغط الاختصار.", "Select one or more files in an Explorer window or on the desktop, then press the shortcut.") : t("الصقه في أي مكان.", "Paste it anywhere."),
    queued: t("بانتظار المهمة السابقة…", "Waiting for the previous job…"),
    running: t(`جارٍ التنفيذ · ${q.processed} / ${q.total}`, `Processing · ${q.processed} / ${q.total}`),
    done: t(`تم حفظ ${q.outputs.length} نتيجة في ${q.folder}. الأصل محفوظ.`, `Saved ${q.outputs.length} result(s) in ${q.folder}. Originals preserved.`),
    failed: q.error || t("تعذر إكمال العملية", "The operation could not finish"),
    cancelled: t(`أُلغيت المهمة. النتائج المكتملة: ${q.outputs.length}`, `Cancelled. Completed results: ${q.outputs.length}`),
  }[q.state];
  const failed = q.state === "failed" || select;
  const status = busy ? h("div", { class: "spinner", role: "progressbar", "aria-label": t("جارٍ المعالجة", "Processing") })
    : h("span", { class: failed ? "ico warn" : "ico" }, icon(failed ? "alert" : q.state === "cancelled" ? "close" : "check"));
  const act = (action) => invoke("toast_action", { action });
  root().replaceChildren(h("div", { class: "toast", role: "status" },
    h("div", { class: "toast-head" }, status, h("b", {}, title),
      h("button", { class: "icon-btn", type: "button", "aria-label": t("إخفاء الإشعار", "Hide notification"), onclick: () => act("close") }, icon("close"))),
    h("p", {}, detail),
    h("div", { class: "toast-actions" },
      q.state === "running" ? h("button", { class: "secondary", type: "button", onclick: () => act("cancel") }, t("إلغاء", "Cancel")) : null,
      q.outputs.length && !busy ? h("button", { class: "secondary", type: "button", onclick: () => act("reveal") }, t("إظهار في المستكشف", "Show in Explorer")) : null)));
}

// ---------- bubble ----------
function loadBubble() {
  const bubble = h("div", { class: "bubble", "data-tauri-drag-region": true, title: "أفلت ملفات هنا · Drop files here" }, mark());
  root().replaceChildren(bubble);
  // Drops are handled natively (with the Shift/Ctrl/Alt state); this only highlights.
  current.onDragDropEvent((e) => bubble.classList.toggle("target", e.payload.type === "enter" || e.payload.type === "over"));
}

// ---------- boot ----------
document.addEventListener("DOMContentLoaded", () => {
  ["dragover", "drop"].forEach((ev) => window.addEventListener(ev, (e) => e.preventDefault()));
  if (current.label === "wheel") {
    loadWheel();
    listen("wheel-changed", () => loadWheel());
    document.addEventListener("keydown", wheelKeys);
  } else if (current.label === "toast") {
    loadToast();
    listen("toast-changed", loadToast);
  } else {
    loadBubble();
  }
});
