//! Desktop quick wheel (Windows port of the Mac Finder drag wheel).
//! Windows cannot read an Explorer drag globally, so the wheel opens from a global hotkey (on the
//! Explorer selection), a floating drop bubble, or the Explorer right-click verb (`--wheel`).
//! Pure helpers (hotkey, catalog, geometry, args, batching) are unit-tested on every platform.

use crate::engine::{self, Cancel, Engines, Job, Kind, Options, Tool};
use crate::AppState;
use serde::{Deserialize, Serialize};
use std::f64::consts::{FRAC_PI_2, TAU};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, DragDropEvent, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow,
    WebviewWindowBuilder, WindowEvent, Wry,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut};

pub const DEFAULT_HOTKEY: &str = "Ctrl+Alt+Z";
const MERGE_WINDOW: Duration = Duration::from_millis(400);
const CELL: (f64, f64) = (68.0, 62.0);
const TOAST: (f64, f64) = (340.0, 132.0);
const BUBBLE: f64 = 64.0;
pub const ACTIONS: [&str; 3] = ["copyPath", "reveal", "openFolder"];

// ---------- hotkey ----------

/// Canonical `Ctrl+Alt+Shift+Win+Key`, or None. Two modifiers are required so a global hotkey
/// never swallows typing or ordinary app shortcuts such as Ctrl+C.
pub fn normalize_hotkey(raw: &str) -> Option<String> {
    let mut mods = [false; 4];
    let mut key: Option<String> = None;
    for token in raw.split('+').map(str::trim) {
        let slot = match token.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => Some(0),
            "alt" => Some(1),
            "shift" => Some(2),
            "win" | "super" | "meta" => Some(3),
            _ => None,
        };
        match slot {
            Some(i) if !mods[i] && key.is_none() => mods[i] = true,
            None if key.is_none() && !token.is_empty() => {
                let fkey =
                    token.len() > 1 && token.starts_with(['f', 'F']) && token[1..].bytes().all(|b| b.is_ascii_digit());
                key = Some(if token.chars().count() == 1 || fkey {
                    token.to_ascii_uppercase()
                } else {
                    token.to_string()
                });
            }
            _ => return None,
        }
    }
    if mods.iter().filter(|m| **m).count() < 2 {
        return None;
    }
    let names = ["Ctrl", "Alt", "Shift", "Win"];
    let mut parts: Vec<&str> = names.iter().zip(mods).filter(|(_, on)| *on).map(|(n, _)| *n).collect();
    parts.push(key.as_deref()?);
    let canonical = parts.join("+");
    to_shortcut(&canonical).map(|_| canonical)
}

pub fn to_shortcut(canonical: &str) -> Option<Shortcut> {
    canonical.replace("Win+", "Super+").parse().ok()
}

// ---------- catalog ----------

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    #[default]
    Convert,
    Tools,
    Actions,
}

pub fn tool_id(tool: Tool) -> String {
    serde_json::to_value(tool).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// Formats every kind can be converted to (same rule as the main panel).
pub fn common_formats(kinds: &[Kind], engines: &Engines) -> Vec<&'static str> {
    let lists: Vec<_> = kinds.iter().map(|k| engines.formats(*k)).collect();
    let Some(first) = lists.first() else { return vec![] };
    first.iter().copied().filter(|f| lists.iter().all(|l| l.contains(f))).collect()
}

/// These need a quality, size, time or format choice, so the wheel opens the main window instead.
pub fn needs_settings(tool: Tool) -> bool {
    matches!(tool, Tool::Compress | Tool::Resize | Tool::Trim | Tool::VideoFrame | Tool::ExtractAudio)
}

/// `(id, needs_settings)` for each ring item of a mode.
pub fn choices(mode: Mode, kinds: &[Kind], engines: &Engines) -> Vec<(String, bool)> {
    match mode {
        Mode::Convert => common_formats(kinds, engines).into_iter().map(|f| (f.to_string(), false)).collect(),
        Mode::Tools => Tool::ALL
            .into_iter()
            .filter(|t| *t != Tool::Convert && !kinds.is_empty() && kinds.iter().all(|k| t.accepts(*k)))
            .map(|t| (tool_id(t), needs_settings(t)))
            .collect(),
        Mode::Actions => ACTIONS.iter().map(|a| (a.to_string(), false)).collect(),
    }
}

/// Port of the Mac `WheelGeometry`: grows the radius until no two cells (plus a 4 px gap) overlap.
/// Returns the window side and the cell centers, clockwise from the top.
pub fn geometry(count: usize) -> (f64, Vec<(f64, f64)>) {
    let (w, h) = CELL;
    let mut radius = 92.0;
    loop {
        let side = ((radius + w / 2.0 + 14.0) * 2.0).ceil();
        let c = side / 2.0;
        let centers: Vec<(f64, f64)> = (0..count)
            .map(|i| {
                let a = -FRAC_PI_2 + i as f64 / count as f64 * TAU;
                (c + a.cos() * radius, c + a.sin() * radius)
            })
            .collect();
        let overlaps = centers
            .iter()
            .enumerate()
            .any(|(i, p)| centers[i + 1..].iter().any(|q| (p.0 - q.0).abs() < w + 4.0 && (p.1 - q.1).abs() < h + 4.0));
        if !overlaps {
            return (side, centers);
        }
        radius += 4.0;
    }
}

/// Top-left that centers `size` on `point`, kept `margin` inside the work area.
pub fn clamp_to_area(
    point: (f64, f64),
    size: (f64, f64),
    origin: (f64, f64),
    area: (f64, f64),
    margin: f64,
) -> (f64, f64) {
    let fit = |p: f64, s: f64, o: f64, a: f64| (p - s / 2.0).min(o + a - s - margin).max(o + margin);
    (fit(point.0, size.0, origin.0, area.0), fit(point.1, size.1, origin.1, area.1))
}

// ---------- right-click launches ----------

/// `--wheel <path>...` (the Explorer verb passes `"%1"`) → absolute paths.
pub fn wheel_args(args: &[String]) -> Option<Vec<String>> {
    let at = args.iter().position(|a| a == "--wheel")?;
    Some(args[at + 1..].iter().filter(|a| Path::new(a).is_absolute()).cloned().collect())
}

/// Explorer starts one process per selected file; paths forwarded within the merge window become
/// one wheel. `push` returns true when it started a new batch (the caller schedules the flush).
#[derive(Default)]
pub struct Batch(Vec<String>);

impl Batch {
    pub fn push(&mut self, paths: Vec<String>) -> bool {
        let was_empty = self.0.is_empty();
        for p in paths {
            if self.0.len() < engine::MAX_INPUTS && !self.0.contains(&p) {
                self.0.push(p);
            }
        }
        was_empty && !self.0.is_empty()
    }
    pub fn take(&mut self) -> Vec<String> {
        std::mem::take(&mut self.0)
    }
}

pub fn forward(app: &AppHandle, paths: Vec<String>) {
    if app.state::<WheelState>().batch.lock().unwrap().push(paths) {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(MERGE_WINDOW).await;
            let paths = app.state::<WheelState>().batch.lock().unwrap().take();
            open_wheel(&app, paths, None);
        });
    }
}

// ---------- state ----------

#[derive(Default)]
struct Session {
    paths: Vec<String>,
    kinds: Vec<Kind>,
    mode: Mode,
    anchor: (f64, f64),
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Quick {
    id: u64,
    /// info | queued | running | done | failed | cancelled
    state: &'static str,
    /// For info: select | copied
    message: &'static str,
    tool: Option<Tool>,
    format: String,
    processed: usize,
    total: usize,
    outputs: Vec<String>,
    error: String,
    folder: String,
    language: String,
    theme: String,
}

#[derive(Default)]
pub struct WheelState {
    session: Mutex<Session>,
    batch: Mutex<Batch>,
    quick: Mutex<Quick>,
    next_quick: AtomicU64,
    /// Job whose toast the user closed: it keeps running without popping up again.
    dismissed: AtomicU64,
    // One quick job at a time; later ones wait (no queue view yet).
    quick_lock: Mutex<()>,
    quick_cancel: Mutex<Cancel>,
    hotkey_active: AtomicBool,
}

// ---------- windows ----------

fn popup(app: &AppHandle, label: &str) -> tauri::Result<WebviewWindow> {
    if let Some(w) = app.get_webview_window(label) {
        return Ok(w);
    }
    let (w, h) = match label {
        "toast" => TOAST,
        "bubble" => (BUBBLE, BUBBLE),
        _ => (340.0, 340.0),
    };
    let window = WebviewWindowBuilder::new(app, label, WebviewUrl::App("quick.html".into()))
        .title("Zawiya Tools")
        .inner_size(w, h)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        // The toast and bubble never take focus from the user's app; the wheel needs the keyboard.
        .focusable(label == "wheel")
        .focused(label == "wheel")
        .build()?;
    let handle = app.clone();
    match label {
        "wheel" => window.on_window_event(move |e| {
            if let WindowEvent::Focused(false) = e {
                hide(&handle, "wheel");
            }
        }),
        "bubble" => window.on_window_event(move |e| {
            if let WindowEvent::DragDrop(DragDropEvent::Drop { paths, .. }) = e {
                let paths = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
                let mode = drop_mode();
                let app = handle.clone();
                std::thread::spawn(move || open_wheel(&app, paths, mode));
            }
        }),
        _ => {}
    }
    Ok(window)
}

fn hide(app: &AppHandle, label: &str) {
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.hide();
    }
}

/// (scale, work-area origin, work-area size) of the monitor under a physical point.
fn work_area(app: &AppHandle, point: (f64, f64)) -> (f64, (f64, f64), (f64, f64)) {
    let monitor =
        app.monitor_from_point(point.0, point.1).ok().flatten().or_else(|| app.primary_monitor().ok().flatten());
    match monitor {
        Some(m) => {
            let a = m.work_area();
            (m.scale_factor(), (a.position.x as f64, a.position.y as f64), (a.size.width as f64, a.size.height as f64))
        }
        None => (1.0, (0.0, 0.0), (1280.0, 720.0)),
    }
}

fn cursor(app: &AppHandle) -> (f64, f64) {
    app.cursor_position().map(|p| (p.x, p.y)).unwrap_or_default()
}

fn place(
    window: &WebviewWindow,
    point: (f64, f64),
    size: (f64, f64),
    at: impl Fn((f64, f64), (f64, f64), (f64, f64), f64) -> (f64, f64),
) {
    let app = window.app_handle();
    let (scale, origin, area) = work_area(app, point);
    let px = (size.0 * scale, size.1 * scale);
    let (x, y) = at(px, origin, area, scale);
    // Position first so the size is applied on the target monitor's DPI.
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
    let _ = window.set_size(PhysicalSize::new(px.0.round() as u32, px.1.round() as u32));
}

fn default_mode(kinds: &[Kind], engines: &Engines) -> Mode {
    [Mode::Convert, Mode::Tools].into_iter().find(|m| !choices(*m, kinds, engines).is_empty()).unwrap_or(Mode::Actions)
}

pub fn open_wheel(app: &AppHandle, paths: Vec<String>, mode: Option<Mode>) {
    let paths: Vec<String> = paths.into_iter().filter(|p| Path::new(p).exists()).take(engine::MAX_INPUTS).collect();
    if paths.is_empty() {
        return info(app, "select");
    }
    let mut kinds = Vec::new();
    for p in &paths {
        let k = Kind::detect(Path::new(p));
        if !kinds.contains(&k) {
            kinds.push(k);
        }
    }
    let engines = &app.state::<AppState>().engines;
    let mode =
        mode.filter(|m| !choices(*m, &kinds, engines).is_empty()).unwrap_or_else(|| default_mode(&kinds, engines));
    *app.state::<WheelState>().session.lock().unwrap() = Session { paths, kinds, mode, anchor: cursor(app) };
    let Ok(window) = popup(app, "wheel") else { return };
    place_wheel(app, &window);
    let _ = app.emit_to("wheel", "wheel-changed", ());
    let _ = window.show();
    let _ = window.set_focus();
}

fn place_wheel(app: &AppHandle, window: &WebviewWindow) {
    let (anchor, count) = {
        let s = app.state::<WheelState>();
        let s = s.session.lock().unwrap();
        (s.anchor, choices(s.mode, &s.kinds, &app.state::<AppState>().engines).len())
    };
    let side = geometry(count).0;
    place(window, anchor, (side, side), |px, origin, area, scale| {
        clamp_to_area(anchor, px, origin, area, 12.0 * scale)
    });
}

/// From the hotkey: the foreground Explorer window. From the tray (`fallback`): the most recent
/// Explorer window, else the desktop, since the taskbar is in front then.
pub fn wheel_for_selection(app: &AppHandle, fallback: bool) {
    let app = app.clone();
    std::thread::spawn(move || {
        let paths = explorer_selection(fallback);
        open_wheel(&app, paths, None);
    });
}

// ---------- tray ----------

fn tray_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let s = app.state::<AppState>().settings.lock().unwrap().clone();
    let t = |a: &'static str, e: &'static str| if s.language == "ar" { a } else { e };
    Menu::with_items(
        app,
        &[
            &MenuItem::with_id(app, "open", t("فتح أداة زاوية", "Open Zawiya Tools"), true, None::<&str>)?,
            &MenuItem::with_id(app, "wheel", t("العجلة السريعة", "Quick wheel"), true, None::<&str>)?,
            &CheckMenuItem::with_id(
                app,
                "bubble",
                t("الفقاعة العائمة", "Floating bubble"),
                true,
                s.bubble,
                None::<&str>,
            )?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, "quit", t("إنهاء", "Quit"), true, None::<&str>)?,
        ],
    )
}

pub fn show_main(app: &AppHandle) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.unminimize();
        let _ = main.show();
        let _ = main.set_focus();
    }
}

/// Tray icon: keeps the hotkey, bubble and right-click wheel reachable while the main window is hidden.
pub fn tray(app: &AppHandle) -> tauri::Result<()> {
    let mut builder = TrayIconBuilder::with_id("main")
        .tooltip("Zawiya Tools · أداة زاوية")
        .menu(&tray_menu(app)?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "wheel" => wheel_for_selection(app, true),
            "bubble" => {
                // Off the main thread: showing the bubble may build its window.
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    let mut settings = app.state::<AppState>().settings.lock().unwrap().clone();
                    settings.bubble = !settings.bubble;
                    if crate::store_settings(&app.state::<AppState>(), settings).is_ok() {
                        apply(&app);
                        let _ = app.emit_to("main", "settings-changed", ());
                    }
                });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

// ---------- commands (wheel window) ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    id: String,
    needs_settings: bool,
    x: f64,
    y: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    mode: Mode,
    side: f64,
    items: Vec<Item>,
    available: [usize; 3],
    paths: Vec<String>,
    language: String,
    theme: String,
}

fn view(app: &AppHandle) -> View {
    let engines = &app.state::<AppState>().engines;
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let ws = app.state::<WheelState>();
    let s = ws.session.lock().unwrap();
    let list = choices(s.mode, &s.kinds, engines);
    let (side, centers) = geometry(list.len());
    View {
        mode: s.mode,
        side,
        items: list
            .into_iter()
            .zip(centers)
            .map(|((id, needs_settings), (x, y))| Item { id, needs_settings, x, y })
            .collect(),
        available: [Mode::Convert, Mode::Tools, Mode::Actions].map(|m| choices(m, &s.kinds, engines).len()),
        paths: s.paths.clone(),
        language: settings.language,
        theme: settings.theme,
    }
}

#[tauri::command]
pub fn wheel_view(app: AppHandle) -> View {
    view(&app)
}

#[tauri::command]
pub fn wheel_mode(app: AppHandle, mode: Mode) -> View {
    app.state::<WheelState>().session.lock().unwrap().mode = mode;
    if let Some(w) = app.get_webview_window("wheel") {
        place_wheel(&app, &w);
    }
    view(&app)
}

#[tauri::command]
pub fn wheel_close(app: AppHandle) {
    hide(&app, "wheel");
}

/// Async: it may build the toast window, which must not happen on the main thread.
#[tauri::command]
pub async fn wheel_run(app: AppHandle, id: String) -> Result<(), String> {
    hide(&app, "wheel");
    let (paths, mode, kinds) = {
        let ws = app.state::<WheelState>();
        let s = ws.session.lock().unwrap();
        (s.paths.clone(), s.mode, s.kinds.clone())
    };
    let first = paths.first().cloned().ok_or_else(engine::err_invalid_options)?;
    let listed = choices(mode, &kinds, &app.state::<AppState>().engines);
    let Some((_, settings_needed)) = listed.into_iter().find(|(c, _)| *c == id) else {
        return Err(engine::err_invalid_options());
    };
    match mode {
        Mode::Convert => run_quick(&app, Tool::Convert, id, paths),
        Mode::Tools => {
            let tool: Tool =
                serde_json::from_value(serde_json::Value::String(id)).map_err(|_| engine::err_invalid_options())?;
            if settings_needed {
                open_main(&app, paths, tool);
            } else {
                run_quick(&app, tool, Options::default().format, paths);
            }
        }
        Mode::Actions => match id.as_str() {
            // The wheel page already wrote the paths to the clipboard.
            "copyPath" => info(&app, "copied"),
            "reveal" => tauri_plugin_opener::reveal_item_in_dir(&first).map_err(|e| e.to_string())?,
            _ => {
                let p = Path::new(&first);
                let folder = if p.is_dir() { p } else { p.parent().ok_or_else(engine::err_invalid_options)? };
                if !folder.is_dir() {
                    return Err(engine::err_invalid_options());
                }
                // Directories only: never launches a file.
                tauri_plugin_opener::open_path(folder, None::<&str>).map_err(|e| e.to_string())?;
            }
        },
    }
    Ok(())
}

fn open_main(app: &AppHandle, paths: Vec<String>, tool: Tool) {
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.unminimize();
        let _ = main.show();
        let _ = main.set_focus();
    }
    let _ = app.emit_to("main", "wheel-open-main", serde_json::json!({ "paths": paths, "tool": tool }));
}

// ---------- quick jobs + toast ----------

fn show_toast(app: &AppHandle, quick: Quick) {
    let id = quick.id;
    let hide_after = match quick.state {
        "info" => Some(3),
        "done" => Some(6),
        _ => None,
    };
    *app.state::<WheelState>().quick.lock().unwrap() = quick;
    let _ = app.emit_to("toast", "toast-changed", ());
    if app.state::<WheelState>().dismissed.load(Ordering::SeqCst) == id {
        return;
    }
    if let Ok(window) = popup(app, "toast") {
        place(&window, cursor(app), TOAST, |px, origin, area, scale| {
            (origin.0 + area.0 - px.0 - 20.0 * scale, origin.1 + area.1 - px.1 - 20.0 * scale)
        });
        let _ = window.show();
    }
    if let Some(secs) = hide_after {
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(secs)).await;
            if app.state::<WheelState>().quick.lock().unwrap().id == id {
                hide(&app, "toast");
            }
        });
    }
}

fn next_id(app: &AppHandle) -> u64 {
    app.state::<WheelState>().next_quick.fetch_add(1, Ordering::SeqCst) + 1
}

fn info(app: &AppHandle, message: &'static str) {
    show_toast(app, Quick { id: next_id(app), state: "info", message, ..Quick::default() });
}

/// Changes the toast only while it still shows job `id`.
fn update(app: &AppHandle, id: u64, change: impl FnOnce(&mut Quick)) {
    let quick = {
        let ws = app.state::<WheelState>();
        let mut q = ws.quick.lock().unwrap();
        if q.id != id {
            return;
        }
        change(&mut q);
        q.clone()
    };
    show_toast(app, quick);
}

fn run_quick(app: &AppHandle, tool: Tool, format: String, paths: Vec<String>) {
    let id = next_id(app);
    let output_dir = app
        .state::<AppState>()
        .settings
        .lock()
        .unwrap()
        .output_dir
        .clone()
        .map(PathBuf::from)
        .unwrap_or_else(|| engine::default_output_dir(Path::new(&paths[0])));
    let inputs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    let groups = if tool.grouped() { vec![inputs] } else { inputs.into_iter().map(|p| vec![p]).collect() };
    show_toast(
        app,
        Quick {
            id,
            state: "queued",
            tool: Some(tool),
            format: format.clone(),
            total: paths.len(),
            folder: output_dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            ..Quick::default()
        },
    );
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let ws = app.state::<WheelState>();
        let _turn = ws.quick_lock.lock().unwrap_or_else(|e| e.into_inner());
        let cancel = Cancel::default();
        *ws.quick_cancel.lock().unwrap() = cancel.clone();
        update(&app, id, |q| q.state = "running");
        let engines = app.state::<AppState>().engines.clone();
        let mut outputs = Vec::new();
        let mut errors = Vec::new();
        for group in groups {
            if cancel.load(Ordering::SeqCst) {
                break;
            }
            let count = group.len();
            let name = group[0].file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let job = Job {
                inputs: group,
                output_dir: output_dir.clone(),
                tool,
                options: Options { format: format.clone(), ..Options::default() },
            };
            match engine::run(&job, &engines, &cancel) {
                Ok(o) => outputs.extend(o.into_iter().map(|p| p.to_string_lossy().into_owned())),
                Err(e) if !cancel.load(Ordering::SeqCst) => errors.push(format!("{name}: {e}")),
                Err(_) => {}
            }
            let shown = outputs.clone();
            update(&app, id, |q| {
                q.processed += count;
                q.outputs = shown;
            });
        }
        let cancelled = cancel.load(Ordering::SeqCst);
        update(&app, id, |q| {
            q.state = if cancelled {
                "cancelled"
            } else if errors.is_empty() {
                "done"
            } else {
                "failed"
            };
            q.error = errors.first().cloned().unwrap_or_default();
        });
    });
}

#[tauri::command]
pub fn toast_state(app: AppHandle) -> Quick {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let mut q = app.state::<WheelState>().quick.lock().unwrap().clone();
    q.language = settings.language;
    q.theme = settings.theme;
    q
}

#[tauri::command]
pub fn toast_action(app: AppHandle, action: String) -> Result<(), String> {
    match action.as_str() {
        "reveal" => {
            let first = app.state::<WheelState>().quick.lock().unwrap().outputs.first().cloned();
            if let Some(path) = first {
                tauri_plugin_opener::reveal_item_in_dir(path).map_err(|e| e.to_string())?;
            }
            hide(&app, "toast");
        }
        "cancel" => app.state::<WheelState>().quick_cancel.lock().unwrap().store(true, Ordering::SeqCst),
        _ => {
            let ws = app.state::<WheelState>();
            ws.dismissed.store(ws.quick.lock().unwrap().id, Ordering::SeqCst);
            hide(&app, "toast");
        }
    }
    Ok(())
}

// ---------- settings ----------

/// Applies hotkey and bubble settings. Called at startup and after every settings save.
pub fn apply(app: &AppHandle) {
    let settings = app.state::<AppState>().settings.lock().unwrap().clone();
    let shortcuts = app.global_shortcut();
    let _ = shortcuts.unregister_all();
    let active =
        settings.hotkey_enabled && to_shortcut(&settings.hotkey).is_some_and(|s| shortcuts.register(s).is_ok());
    app.state::<WheelState>().hotkey_active.store(active, Ordering::SeqCst);
    // Labels follow the language; the bubble check follows the setting.
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("main"), tray_menu(app)) {
        let _ = tray.set_menu(Some(menu));
    }
    if !settings.bubble {
        return hide(app, "bubble");
    }
    if let Ok(window) = popup(app, "bubble") {
        if !window.is_visible().unwrap_or(false) {
            place(&window, (0.0, 0.0), (BUBBLE, BUBBLE), |px, origin, area, scale| {
                (origin.0 + area.0 - px.0 - 24.0 * scale, origin.1 + area.1 - px.1 - 180.0 * scale)
            });
            let _ = window.show();
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    hotkey_active: bool,
    context_menu: bool,
}

#[tauri::command]
pub fn wheel_status(app: AppHandle) -> Status {
    Status {
        hotkey_active: app.state::<WheelState>().hotkey_active.load(Ordering::SeqCst),
        context_menu: context_menu_installed(),
    }
}

// ---------- Windows integration ----------

/// Shift → convert, Ctrl → tools, Alt → actions while dropping on the bubble.
fn drop_mode() -> Option<Mode> {
    #[cfg(windows)]
    {
        use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_CONTROL, VK_MENU, VK_SHIFT};
        let down =
            |vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY| unsafe { GetAsyncKeyState(vk.0 as i32) } < 0;
        if down(VK_SHIFT) {
            return Some(Mode::Convert);
        }
        if down(VK_CONTROL) {
            return Some(Mode::Tools);
        }
        if down(VK_MENU) {
            return Some(Mode::Actions);
        }
    }
    None
}

/// Whether the installer's per-user Explorer verb is present.
pub fn context_menu_installed() -> bool {
    #[cfg(windows)]
    {
        use windows::core::{w, PCWSTR};
        use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_SZ};
        unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                w!(r"Software\Classes\*\shell\ZawiyaTools\command"),
                PCWSTR::null(),
                RRF_RT_REG_SZ,
                None,
                None,
                None,
            )
            .is_ok()
        }
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Paths selected in the foreground Explorer window (active tab) or on the desktop.
/// `fallback`: when neither is in front, use the most recent Explorer window, else the desktop.
pub fn explorer_selection(fallback: bool) -> Vec<String> {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED};
        let foreground = windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow();
        let init = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let paths = shell::selection(foreground, fallback).unwrap_or_default();
        if init.is_ok() {
            CoUninitialize();
        }
        paths
    }
    #[cfg(not(windows))]
    {
        let _ = fallback;
        Vec::new()
    }
}

#[cfg(windows)]
mod shell {
    use windows::core::{w, Interface, Result, PCWSTR};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::Com::{CoCreateInstance, IDispatch, IServiceProvider, CLSCTX_ALL};
    use windows::Win32::System::Variant::{VARIANT, VT_I4};
    use windows::Win32::UI::Shell::{
        IShellBrowser, IShellFolderViewDual, IShellWindows, IWebBrowser2, SID_STopLevelBrowser, ShellWindows,
        CSIDL_DESKTOP, SVGIO_BACKGROUND, SWC_DESKTOP, SWFO_NEEDDISPATCH,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        FindWindowExW, GetClassNameW, GetTopWindow, GetWindow, IsWindowVisible, GW_HWNDNEXT,
    };

    unsafe fn class_of(window: HWND) -> String {
        let mut class = [0u16; 64];
        let len = GetClassNameW(window, &mut class).max(0) as usize;
        String::from_utf16_lossy(&class[..len])
    }

    pub unsafe fn selection(mut foreground: HWND, fallback: bool) -> Result<Vec<String>> {
        let windows: IShellWindows = CoCreateInstance(&ShellWindows, None, CLSCTX_ALL)?;
        let mut class = class_of(foreground);
        if fallback && !matches!(class.as_str(), "CabinetWClass" | "Progman" | "WorkerW") {
            // Walk the z-order from the top: the first visible Explorer frame is the most recent one.
            class = "Progman".into();
            let mut next = GetTopWindow(None).ok();
            while let Some(window) = next {
                if IsWindowVisible(window).as_bool() && class_of(window) == "CabinetWClass" {
                    (foreground, class) = (window, "CabinetWClass".into());
                    break;
                }
                next = GetWindow(window, GW_HWNDNEXT).ok();
            }
        }
        if class == "Progman" || class == "WorkerW" {
            let mut hwnd = 0;
            let desktop = windows.FindWindowSW(
                &int(CSIDL_DESKTOP as i32),
                &VARIANT::default(),
                SWC_DESKTOP,
                &mut hwnd,
                SWFO_NEEDDISPATCH,
            )?;
            return selected(&browser(&desktop)?);
        }
        // Windows 11 tabs share one frame; the first ShellTabWindowClass child is the active tab.
        let active_tab = FindWindowExW(Some(foreground), None, w!("ShellTabWindowClass"), PCWSTR::null()).ok();
        for i in 0..windows.Count()? {
            let Ok(item) = windows.Item(&int(i)) else { continue };
            let Ok(web) = item.cast::<IWebBrowser2>() else { continue };
            if web.HWND().ok().map(|h| h.0) != Some(foreground.0 as isize) {
                continue;
            }
            let Ok(b) = browser(&item) else { continue };
            if active_tab.is_some() && b.GetWindow().ok() != active_tab {
                continue;
            }
            return selected(&b);
        }
        Ok(Vec::new())
    }

    fn int(value: i32) -> VARIANT {
        let mut v = VARIANT::default();
        // SAFETY: plain VT_I4 variant; nothing to free.
        unsafe {
            let inner = &mut *v.Anonymous.Anonymous;
            inner.vt = VT_I4;
            inner.Anonymous.lVal = value;
        }
        v
    }

    unsafe fn browser(item: &IDispatch) -> Result<IShellBrowser> {
        item.cast::<IServiceProvider>()?.QueryService(&SID_STopLevelBrowser)
    }

    unsafe fn selected(browser: &IShellBrowser) -> Result<Vec<String>> {
        let view: IShellFolderViewDual = browser.QueryActiveShellView()?.GetItemObject(SVGIO_BACKGROUND)?;
        let items = view.SelectedItems()?;
        let mut out = Vec::new();
        for i in 0..items.Count()? {
            if let Ok(path) = items.Item(&int(i)).and_then(|item| item.Path()) {
                out.push(path.to_string());
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn engines() -> Engines {
        Engines {
            ffmpeg: Some(PathBuf::from("ffmpeg")),
            encoders: ["libwebp", "libmp3lame", "libopus", "libsvtav1"]
                .into_iter()
                .map(String::from)
                .collect::<HashSet<_>>(),
            pdfium_dir: None,
        }
    }

    #[test]
    fn hotkeys() {
        assert_eq!(normalize_hotkey(DEFAULT_HOTKEY).as_deref(), Some("Ctrl+Alt+Z"));
        assert_eq!(normalize_hotkey("alt+ctrl+z").as_deref(), Some("Ctrl+Alt+Z"));
        assert_eq!(normalize_hotkey(" shift + control + z ").as_deref(), Some("Ctrl+Shift+Z"));
        assert_eq!(normalize_hotkey("Alt+Win+f5").as_deref(), Some("Alt+Win+F5"));
        assert_eq!(normalize_hotkey("Ctrl+Alt+Space").as_deref(), Some("Ctrl+Alt+Space"));
        assert_eq!(normalize_hotkey("Ctrl+Alt+Digit1").as_deref(), Some("Ctrl+Alt+Digit1"));
        for bad in [
            "Z",
            "Ctrl+Z",
            "Shift+Z",
            "Ctrl+Shift",
            "Ctrl+Ctrl+Z",
            "Ctrl+Shift+Z+X",
            "Ctrl+Z+Shift",
            "Ctrl+Shift+ز",
            "",
            "Ctrl++Z",
        ] {
            assert_eq!(normalize_hotkey(bad), None, "{bad}");
        }
        assert!(to_shortcut("Alt+Win+F5").is_some());
    }

    #[test]
    fn catalog_per_kind() {
        let e = engines();
        let ids = |m, k: &[Kind]| choices(m, k, &e).into_iter().map(|c| c.0).collect::<Vec<_>>();
        assert_eq!(ids(Mode::Convert, &[Kind::Image]), ["jpg", "png", "webp", "tiff", "bmp", "pdf"]);
        assert_eq!(ids(Mode::Convert, &[Kind::Image, Kind::Pdf]), ["jpg", "png"]);
        assert!(ids(Mode::Convert, &[Kind::Image, Kind::Audio]).is_empty());
        assert!(ids(Mode::Convert, &[Kind::Folder]).is_empty());
        assert_eq!(ids(Mode::Tools, &[Kind::Pdf]), ["mergePdf", "splitPdf", "extractText", "zip"]);
        assert_eq!(ids(Mode::Tools, &[Kind::Folder]), ["zip"]);
        assert_eq!(ids(Mode::Tools, &[Kind::Image, Kind::Video]), ["compress", "stripMetadata", "zip"]);
        let video = choices(Mode::Tools, &[Kind::Video], &e);
        assert!(video.contains(&("trim".into(), true)) && video.contains(&("stripMetadata".into(), false)));
        assert!(!video.iter().any(|c| c.0 == "convert"));
        assert_eq!(ids(Mode::Actions, &[Kind::Unknown]), ACTIONS);
        assert_eq!(default_mode(&[Kind::Image, Kind::Audio], &e), Mode::Tools);
        assert_eq!(default_mode(&[Kind::Video], &e), Mode::Convert);
        assert_eq!(default_mode(&[], &e), Mode::Actions);
    }

    #[test]
    fn geometry_has_no_overlaps() {
        for n in 0..=14 {
            let (side, centers) = geometry(n);
            assert_eq!(centers.len(), n);
            for (i, p) in centers.iter().enumerate() {
                assert!(p.0 - CELL.0 / 2.0 >= 0.0 && p.0 + CELL.0 / 2.0 <= side && p.1 - CELL.1 / 2.0 >= 0.0, "{n}");
                for q in &centers[i + 1..] {
                    assert!((p.0 - q.0).abs() >= CELL.0 + 4.0 || (p.1 - q.1).abs() >= CELL.1 + 4.0, "{n}");
                }
            }
        }
        let (side, top) = geometry(6);
        assert_eq!(side, 280.0);
        assert!((top[0].0 - 140.0).abs() < 1e-9 && top[0].1 < top[1].1 && top[1].0 > 140.0, "clockwise from the top");
        assert_eq!(clamp_to_area((5.0, 990.0), (300.0, 300.0), (0.0, 0.0), (1920.0, 1000.0), 12.0), (12.0, 688.0));
        assert_eq!(clamp_to_area((900.0, 500.0), (300.0, 300.0), (0.0, 0.0), (1920.0, 1000.0), 12.0), (750.0, 350.0));
    }

    #[test]
    fn wheel_arguments() {
        let a = std::env::temp_dir().join("a b.png").to_string_lossy().into_owned();
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(wheel_args(&args(&["zawiya.exe", "--wheel", &a])), Some(vec![a.clone()]));
        assert_eq!(wheel_args(&args(&["zawiya.exe", "--wheel", "relative.png", &a])), Some(vec![a.clone()]));
        assert_eq!(wheel_args(&args(&["zawiya.exe", "--wheel"])), Some(vec![]));
        assert_eq!(wheel_args(&args(&["zawiya.exe", &a])), None);
    }

    #[test]
    fn merges_forwarded_paths() {
        let mut b = Batch::default();
        assert!(!b.push(vec![]), "empty push opens nothing");
        assert!(b.push(vec!["a".into()]), "first path opens a batch");
        assert!(!b.push(vec!["b".into(), "a".into()]), "later paths join it");
        assert_eq!(b.take(), ["a", "b"]);
        assert!(b.push(vec!["c".into()]), "after the flush a new batch starts");
        b.take();
        assert!(b.push((0..engine::MAX_INPUTS + 5).map(|i| i.to_string()).collect()));
        assert_eq!(b.take().len(), engine::MAX_INPUTS);
    }
}
