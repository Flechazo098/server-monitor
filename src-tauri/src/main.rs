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

#[cfg(windows)]
mod process_job {
    use std::ffi::c_void;
    use std::io;
    use std::mem::size_of;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
    };

    pub struct ProcessJob(HANDLE);

    // A job handle is an opaque kernel object and can safely be held by
    // Tauri's shared application state.
    unsafe impl Send for ProcessJob {}
    unsafe impl Sync for ProcessJob {}

    impl ProcessJob {
        pub fn new() -> io::Result<Self> {
            let handle = unsafe { CreateJobObjectW(null(), null()) };
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }

            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let configured = unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &limits as *const _ as *const c_void,
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
            };
            if configured == 0 {
                unsafe { CloseHandle(handle) };
                return Err(io::Error::last_os_error());
            }
            Ok(Self(handle))
        }

        pub fn assign(&self, pid: u32) -> io::Result<()> {
            let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid) };
            if process.is_null() {
                return Err(io::Error::last_os_error());
            }
            let assigned = unsafe { AssignProcessToJobObject(self.0, process) };
            unsafe { CloseHandle(process) };
            if assigned == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
    }

    impl Drop for ProcessJob {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CloseHandle(self.0) };
                self.0 = null_mut();
            }
        }
    }
}

#[derive(Serialize, Clone)]
struct BackendInfo {
    port: u16,
    token: String,
}

struct BackendState {
    info: Mutex<Option<BackendInfo>>,
    child: Mutex<Option<CommandChild>>,
    #[cfg(windows)]
    job: Mutex<Option<process_job::ProcessJob>>,
}

#[tauri::command]
fn get_backend_info(state: State<BackendState>) -> Result<BackendInfo, String> {
    state
        .info
        .lock()
        .map_err(|_| "backend state lock poisoned".to_string())?
        .clone()
        .ok_or_else(|| "backend not ready".into())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_shell::init())
        .manage(BackendState {
            info: Mutex::new(None),
            child: Mutex::new(None),
            #[cfg(windows)]
            job: Mutex::new(None),
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

            #[cfg(windows)]
            {
                let job = process_job::ProcessJob::new()
                    .map_err(|e| format!("sidecar job create: {e}"))?;
                if let Err(error) = job.assign(child.pid()) {
                    let _ = child.kill();
                    return Err(format!("sidecar job assign: {error}").into());
                }
                *state
                    .job
                    .lock()
                    .map_err(|_| "backend job lock poisoned".to_string())? = Some(job);
            }

            *state
                .child
                .lock()
                .map_err(|_| "backend child lock poisoned".to_string())? = Some(child);

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
                                            if let Ok(mut info) = st.info.lock() {
                                                *info = Some(BackendInfo {
                                                    port,
                                                    token: tok.to_string(),
                                                });
                                                let _ = app_handle.emit("backend-ready", ());
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        CommandEvent::Stderr(line) => {
                            eprintln!("[sidecar] {}", String::from_utf8_lossy(&line));
                        }
                        CommandEvent::Error(error) => {
                            eprintln!("[sidecar] process error: {error}");
                        }
                        CommandEvent::Terminated(payload) => {
                            if let Some(st) = app_handle.try_state::<BackendState>() {
                                if let Ok(mut info) = st.info.lock() {
                                    *info = None;
                                }
                                if let Ok(mut child) = st.child.lock() {
                                    *child = None;
                                }
                                #[cfg(windows)]
                                if let Ok(mut job) = st.job.lock() {
                                    *job = None;
                                }
                            }
                            let _ = app_handle.emit("backend-exited", payload.code);
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
                    if let Ok(mut child_slot) = st.child.lock() {
                        if let Some(child) = child_slot.take() {
                            let _ = child.kill();
                        }
                    }
                    #[cfg(windows)]
                    if let Ok(mut job_slot) = st.job.lock() {
                        *job_slot = None;
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
