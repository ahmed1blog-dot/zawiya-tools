pub mod banner;
pub mod engine;
pub mod ocr;
pub mod pdf;
pub mod wheel;

use engine::{Cancel, Engines, Job, Kind, Options, Tool};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub language: String,
    pub theme: String,
    pub auto_update: bool,
    pub output_dir: Option<String>,
    pub dismissed_banner: Option<String>,
    pub hotkey_enabled: bool,
    pub hotkey: String,
    pub bubble: bool,
    pub keep_in_tray: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: "ar".into(),
            theme: "dark".into(),
            auto_update: true,
            output_dir: None,
            dismissed_banner: None,
            hotkey_enabled: true,
            hotkey: wheel::DEFAULT_HOTKEY.into(),
            bubble: false,
            keep_in_tray: true,
        }
    }
}

impl Settings {
    fn sanitized(mut self) -> Self {
        if !["ar", "en"].contains(&self.language.as_str()) {
            self.language = "ar".into();
        }
        if !["dark", "light", "system"].contains(&self.theme.as_str()) {
            self.theme = "dark".into();
        }
        self.output_dir = self.output_dir.filter(|p| p.len() <= 4096 && Path::new(p).is_absolute());
        self.dismissed_banner = self.dismissed_banner.filter(|id| id.len() <= 64);
        self.hotkey = wheel::normalize_hotkey(&self.hotkey).unwrap_or_else(|| wheel::DEFAULT_HOTKEY.into());
        self
    }
}

struct AppState {
    engines: Engines,
    config_dir: PathBuf,
    data_dir: PathBuf,
    settings: Mutex<Settings>,
    jobs: Mutex<HashMap<String, Cancel>>,
    banner: Mutex<Option<banner::Banner>>,
    update: Mutex<Option<(Update, Vec<u8>)>>,
    update_busy: AtomicBool,
}

fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", uuid::Uuid::new_v4()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolInfo {
    id: Tool,
    accepts: Vec<Kind>,
    grouped: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    version: String,
    ffmpeg: bool,
    pdfium: bool,
    ocr_languages: Vec<String>,
    tools: Vec<ToolInfo>,
    formats: HashMap<Kind, Vec<&'static str>>,
}

const KINDS: [Kind; 9] = [
    Kind::Image,
    Kind::Video,
    Kind::Audio,
    Kind::Pdf,
    Kind::Subtitle,
    Kind::Archive,
    Kind::Document,
    Kind::Folder,
    Kind::Unknown,
];

#[tauri::command]
async fn app_info(app: AppHandle, state: State<'_, AppState>) -> Result<AppInfo, String> {
    let e = &state.engines;
    let ocr_languages = tauri::async_runtime::spawn_blocking(ocr::languages).await.unwrap_or_default();
    Ok(AppInfo {
        version: app.package_info().version.to_string(),
        ffmpeg: e.ffmpeg.is_some(),
        pdfium: e.pdfium_dir.is_some(),
        ocr_languages,
        tools: Tool::ALL
            .iter()
            .map(|t| ToolInfo {
                id: *t,
                accepts: KINDS.into_iter().filter(|k| t.accepts(*k)).collect(),
                grouped: t.grouped(),
            })
            .collect(),
        formats: KINDS.into_iter().map(|k| (k, e.formats(k))).collect(),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    path: String,
    name: String,
    kind: Kind,
    bytes: u64,
}

#[tauri::command]
fn inspect(paths: Vec<String>) -> Vec<Entry> {
    paths
        .into_iter()
        .take(engine::MAX_INPUTS)
        .filter_map(|p| {
            let path = PathBuf::from(&p);
            let meta = std::fs::metadata(&path).ok()?;
            Some(Entry {
                name: path.file_name()?.to_string_lossy().into_owned(),
                kind: Kind::detect(&path),
                bytes: if meta.is_file() { meta.len() } else { 0 },
                path: p,
            })
        })
        .collect()
}

fn paths_to_strings(paths: Option<Vec<tauri_plugin_dialog::FilePath>>) -> Vec<String> {
    paths
        .unwrap_or_default()
        .into_iter()
        .filter_map(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned())
        .collect()
}

#[tauri::command]
async fn pick_files(app: AppHandle) -> Vec<String> {
    paths_to_strings(app.dialog().file().blocking_pick_files())
}

#[tauri::command]
async fn pick_folder(app: AppHandle) -> Vec<String> {
    paths_to_strings(app.dialog().file().blocking_pick_folder().map(|p| vec![p]))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JobResult {
    outputs: Vec<String>,
    bytes: u64,
}

#[tauri::command]
async fn run_job(
    state: State<'_, AppState>,
    job_id: String,
    tool: Tool,
    inputs: Vec<String>,
    options: Options,
    output_dir: Option<String>,
) -> Result<JobResult, String> {
    let inputs: Vec<PathBuf> = inputs.into_iter().map(PathBuf::from).collect();
    let first = inputs.first().ok_or_else(engine::err_invalid_options)?;
    let output_dir = output_dir.map(PathBuf::from).unwrap_or_else(|| engine::default_output_dir(first));
    let cancel: Cancel = Default::default();
    state.jobs.lock().unwrap().insert(job_id.clone(), cancel.clone());
    let engines = state.engines.clone();
    let job = Job { inputs, output_dir, tool, options };
    let result = tauri::async_runtime::spawn_blocking(move || engine::run(&job, &engines, &cancel)).await;
    state.jobs.lock().unwrap().remove(&job_id);
    let outputs = result.map_err(|e| e.to_string())??;
    let bytes = outputs.iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum();
    Ok(JobResult { outputs: outputs.iter().map(|p| p.to_string_lossy().into_owned()).collect(), bytes })
}

#[tauri::command]
fn cancel_job(state: State<'_, AppState>, job_id: String) {
    if let Some(c) = state.jobs.lock().unwrap().get(&job_id) {
        c.store(true, Ordering::SeqCst);
    }
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_link(url: String) -> Result<(), String> {
    let ok = url::Url::parse(&url).is_ok_and(|u| u.scheme() == "https" && u.host_str().is_some());
    if !ok {
        return Err("https only".into());
    }
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_settings(state: State<'_, AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

/// Async: applying the wheel settings may build the bubble window, which must not run on the main thread.
#[tauri::command]
async fn save_settings(app: AppHandle, state: State<'_, AppState>, settings: Settings) -> Result<Settings, String> {
    if wheel::normalize_hotkey(&settings.hotkey).is_none() {
        return Err("اختصار غير صالح: استخدم معدّلين ومفتاحاً، مثل Ctrl+Alt+Z / Invalid shortcut: use two modifiers and a key, e.g. Ctrl+Alt+Z".into());
    }
    let settings = store_settings(&state, settings)?;
    wheel::apply(&app);
    Ok(settings)
}

fn store_settings(state: &AppState, settings: Settings) -> Result<Settings, String> {
    let settings = settings.sanitized();
    let json = serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?;
    write_atomic(&state.config_dir.join("settings.json"), &json).map_err(|e| e.to_string())?;
    *state.settings.lock().unwrap() = settings.clone();
    Ok(settings)
}

#[tauri::command]
fn get_banner(state: State<'_, AppState>) -> Option<banner::Banner> {
    let dismissed = state.settings.lock().unwrap().dismissed_banner.clone();
    state.banner.lock().unwrap().clone().filter(|b| Some(&b.id) != dismissed.as_ref())
}

#[tauri::command]
async fn dismiss_banner(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let mut settings = state.settings.lock().unwrap().clone();
    settings.dismissed_banner = Some(id);
    save_settings(app, state, settings).await.map(|_| ())
}

async fn refresh_banner(app: &AppHandle) {
    let state = app.state::<AppState>();
    let version = app.package_info().version.to_string();
    let Ok(raw) = banner::fetch(&version).await else { return }; // offline: keep cached state
    let mut shown = match banner::validate(&raw, banner::today()) {
        Ok(valid) => {
            let _ = write_atomic(&state.data_dir.join("banner.json"), &raw);
            valid
        }
        Err(_) => None,
    };
    if let Some(b) = shown.as_mut() {
        banner::attach_image(b, &version).await;
    }
    *state.banner.lock().unwrap() = shown;
    let _ = app.emit("banner-changed", ());
}

/// Checks, then downloads in the background. Returns "none" | "ready" | "busy".
async fn check_update(app: &AppHandle) -> Result<&'static str, String> {
    let state = app.state::<AppState>();
    if state.update.lock().unwrap().is_some() {
        return Ok("ready");
    }
    if state.update_busy.swap(true, Ordering::SeqCst) {
        return Ok("busy");
    }
    let result = async {
        let Some(update) = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())? else {
            return Ok("none");
        };
        let bytes = update.download(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
        let version = update.version.clone();
        *state.update.lock().unwrap() = Some((update, bytes));
        let _ = app.emit("update-ready", version);
        Ok("ready")
    }
    .await;
    state.update_busy.store(false, Ordering::SeqCst);
    result
}

#[tauri::command]
async fn check_for_updates(app: AppHandle) -> Result<&'static str, String> {
    check_update(&app).await
}

#[tauri::command]
fn restart_to_update(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    let Some((update, bytes)) = state.update.lock().unwrap().take() else { return Err("no update".into()) };
    update.install(bytes).map_err(|e| e.to_string())?;
    app.restart();
}

fn setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let paths = app.path();
    let config_dir = paths.app_config_dir()?;
    let data_dir = paths.app_data_dir()?;
    let resource_bin = paths.resource_dir().ok().map(|d| d.join("bin"));
    let settings: Settings = std::fs::read(config_dir.join("settings.json"))
        .ok()
        .and_then(|d| serde_json::from_slice::<Settings>(&d).ok())
        .unwrap_or_default()
        .sanitized();
    let cached = std::fs::read(data_dir.join("banner.json"))
        .ok()
        .and_then(|raw| banner::validate(&raw, banner::today()).ok().flatten());
    app.manage(AppState {
        engines: Engines::detect(resource_bin),
        config_dir,
        data_dir,
        settings: Mutex::new(settings),
        jobs: Mutex::default(),
        banner: Mutex::new(cached),
        update: Mutex::default(),
        update_busy: AtomicBool::new(false),
    });
    app.manage(wheel::WheelState::default());
    wheel::tray(app.handle())?;
    // A right-click launch (`--wheel`) stays in the background; a normal launch shows the window.
    let launch = wheel::wheel_args(&std::env::args().collect::<Vec<_>>());
    if launch.is_none() {
        if let Some(main) = app.get_webview_window("main") {
            main.show()?;
        }
    }
    let handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        wheel::apply(&handle);
        if let Some(paths) = launch {
            wheel::forward(&handle, paths);
        }
    });
    let handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        loop {
            refresh_banner(&handle).await;
            tokio::time::sleep(Duration::from_secs(6 * 3600)).await;
        }
    });
    let handle = app.handle().clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        loop {
            let auto = handle.state::<AppState>().settings.lock().unwrap().auto_update;
            if auto {
                let _ = check_update(&handle).await;
            }
            tokio::time::sleep(Duration::from_secs(12 * 3600)).await;
        }
    });
    Ok(())
}

pub fn run() {
    // A right-click launch hands its paths to the running app, which may then bring the wheel forward.
    #[cfg(windows)]
    unsafe {
        let _ = windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow(
            windows::Win32::UI::WindowsAndMessaging::ASFW_ANY,
        );
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| match wheel::wheel_args(&args) {
            Some(paths) => wheel::forward(app, paths),
            None => wheel::show_main(app),
        }))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _, event| {
                    if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                        wheel::wheel_for_selection(app, false);
                    }
                })
                .build(),
        )
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(setup)
        .on_window_event(|window, event| {
            if window.label() != "main" {
                return;
            }
            let keep = window.try_state::<AppState>().is_some_and(|s| s.settings.lock().unwrap().keep_in_tray);
            match event {
                // Hide to the tray so the hotkey, bubble and right-click wheel keep working.
                tauri::WindowEvent::CloseRequested { api, .. } if keep => {
                    api.prevent_close();
                    let _ = window.hide();
                }
                // Otherwise closing quits (the hidden popup windows would keep the app alive).
                // `exit`, `restart` and the updater's install never send CloseRequested, so they still quit.
                tauri::WindowEvent::Destroyed => window.app_handle().exit(0),
                _ => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_info,
            inspect,
            pick_files,
            pick_folder,
            run_job,
            cancel_job,
            reveal,
            open_link,
            get_settings,
            save_settings,
            get_banner,
            dismiss_banner,
            check_for_updates,
            restart_to_update,
            wheel::wheel_status,
            wheel::wheel_view,
            wheel::wheel_mode,
            wheel::wheel_run,
            wheel::wheel_close,
            wheel::toast_state,
            wheel::toast_action
        ])
        .run(tauri::generate_context!())
        .expect("error while running Zawiya Tools");
}
