fn main() {
    // Each window's capability lists exactly the app commands it may call.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
        "app_info",
        "inspect",
        "pick_files",
        "pick_folder",
        "run_job",
        "cancel_job",
        "reveal",
        "open_link",
        "get_settings",
        "save_settings",
        "get_banner",
        "dismiss_banner",
        "check_for_updates",
        "restart_to_update",
        "wheel_status",
        "wheel_view",
        "wheel_mode",
        "wheel_run",
        "wheel_close",
        "toast_state",
        "toast_action",
    ])))
    .expect("failed to run tauri-build");
}
