// Server Monitor desktop shell.
//
// Responsibilities (deliberately narrow):
//   1. window + lifecycle
//   2. spawn/stop the Haskell sidecar (monitor-backend)
//   3. parse "READY <port> <token>" from sidecar stdout
//   4. expose {port, token} to the Vue frontend via `get_backend_info`
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rand::distributions::Alphanumeric;
use rand::Rng;
use serde::Serialize;
use std::sync::Mutex;
use tauri::{Emitter, Manager, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

#[derive(Serialize, Clone)]
struct BackendInfo {
    port: u16,
    token: String,
}

struct BackendState {
    info: Mutex<Option<BackendInfo>>,
    child: Mutex<Option<CommandChild>>,
}

#[tauri::command]
fn get_backend_info(state: State<BackendState>) -> Result<BackendInfo, String> {
    state
        .info
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "backend not ready".into())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(BackendState {
            info: Mutex::new(None),
            child: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![get_backend_info])
        .setup(|app| {
            let token: String = rand::thread_rng()
                .sample_iter(&Alphanumeric)
                .take(32)
                .map(char::from)
                .collect();

            // Dev builds read the project backend config; packaged builds
            // expect config.json next to the executable.
            let config_path = if cfg!(debug_assertions) {
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../backend/config.json")
            } else {
                std::env::current_exe()
                    .map_err(|e| e.to_string())?
                    .parent()
                    .map(|p| p.join("config.json"))
                    .ok_or_else(|| "cannot resolve executable directory".to_string())?
            };
            let config_str = config_path.to_string_lossy().to_string();

            let state = app.state::<BackendState>();
            let sidecar = app
                .shell()
                .sidecar("monitor-backend")
                .map_err(|e| format!("sidecar resolve: {e}"))?;

            let (mut rx, child) = sidecar
                .args(["--token", &token, "--config", &config_str])
                .spawn()
                .map_err(|e| format!("sidecar spawn: {e}"))?;

            *state.child.lock().unwrap() = Some(child);

            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Some(event) = rx.recv().await {
                    match event {
                        CommandEvent::Stdout(line) => {
                            let text = String::from_utf8_lossy(&line);
                            if let Some(rest) = text.strip_prefix("READY ") {
                                let mut parts = rest.trim().splitn(2, ' ');
                                if let (Some(port_s), Some(tok)) = (parts.next(), parts.next()) {
                                    if let Ok(port) = port_s.parse::<u16>() {
                                        if let Some(st) = app_handle.try_state::<BackendState>() {
                                            *st.info.lock().unwrap() = Some(BackendInfo {
                                                port,
                                                token: tok.to_string(),
                                            });
                                            let _ = app_handle.emit("backend-ready", ());
                                        }
                                    }
                                }
                            }
                        }
                        CommandEvent::Stderr(line) => {
                            eprintln!("[sidecar] {}", String::from_utf8_lossy(&line));
                        }
                        _ => {}
                    }
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                if let Some(st) = window.app_handle().try_state::<BackendState>() {
                    if let Some(child) = st.child.lock().unwrap().take() {
                        let _ = child.kill();
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
