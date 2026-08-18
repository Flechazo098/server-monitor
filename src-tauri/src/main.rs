// Server Monitor desktop shell.
//
// The shell owns local lifecycle and protected configuration only. Remote
// collection remains in the read-only Haskell sidecar.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use rand::distributions::Alphanumeric;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{Emitter, Manager, State};
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

const CONFIG_ENTROPY: &[u8] = b"cc.sighs.server-monitor/config/v1";
const CONFIG_FILE: &str = "config.dpapi";

#[cfg(windows)]
mod protected_data {
    use super::CONFIG_ENTROPY;
    use std::io;
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    fn blob(bytes: &[u8]) -> io::Result<CRYPT_INTEGER_BLOB> {
        let len = u32::try_from(bytes.len()).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "configuration is too large")
        })?;
        Ok(CRYPT_INTEGER_BLOB {
            cbData: len,
            pbData: bytes.as_ptr().cast_mut(),
        })
    }

    pub fn protect(plain: &[u8]) -> io::Result<Vec<u8>> {
        let input = blob(plain)?;
        let entropy = blob(CONFIG_ENTROPY)?;
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptProtectData(
                &input,
                null(),
                &entropy,
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let cipher =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
        unsafe { LocalFree(output.pbData.cast()) };
        Ok(cipher)
    }

    pub fn unprotect(cipher: &[u8]) -> io::Result<Vec<u8>> {
        let input = blob(cipher)?;
        let entropy = blob(CONFIG_ENTROPY)?;
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = unsafe {
            CryptUnprotectData(
                &input,
                null_mut(),
                &entropy,
                null(),
                null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        let plain = unsafe {
            let bytes = std::slice::from_raw_parts_mut(output.pbData, output.cbData as usize);
            let copy = bytes.to_vec();
            bytes.fill(0);
            copy
        };
        unsafe { LocalFree(output.pbData.cast()) };
        Ok(plain)
    }
}

#[cfg(not(windows))]
mod protected_data {
    use std::io;

    pub fn protect(_: &[u8]) -> io::Result<Vec<u8>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "protected configuration requires Windows DPAPI",
        ))
    }

    pub fn unprotect(_: &[u8]) -> io::Result<Vec<u8>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "protected configuration requires Windows DPAPI",
        ))
    }
}

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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AlertConfig {
    disk_pct: f64,
    mem_pct: f64,
    cpu_pct: f64,
    cpu_sustain_sec: u32,
    tls_min_days: u32,
    health_max_fails: u32,
    backup_max_age_hours: u32,
    cooldown_sec: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CollectionConfig {
    full_interval_sec: u32,
    timeout_sec: u32,
    retention_days: u32,
    backoff_max_sec: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ServerConfig {
    id: String,
    name: String,
    ssh_host: String,
    ssh_port: u16,
    ssh_user: String,
    ssh_key: String,
    interval_sec: u32,
    public_urls: Vec<String>,
    cert_hosts: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MonitorConfig {
    db_path: String,
    alerts: AlertConfig,
    collection: CollectionConfig,
    servers: Vec<ServerConfig>,
}

impl MonitorConfig {
    fn validate(&self) -> Result<(), String> {
        if self.db_path.trim().is_empty() {
            return Err("dbPath must not be empty".into());
        }
        if self.servers.is_empty() {
            return Err("servers must not be empty".into());
        }
        let mut ids = std::collections::HashSet::new();
        for server in &self.servers {
            if server.id.is_empty()
                || !server
                    .id
                    .chars()
                    .all(|c| c.is_alphanumeric() || matches!(c, '.' | '_' | '-'))
            {
                return Err("server id may contain only letters, digits, '.', '_' or '-'".into());
            }
            if !ids.insert(&server.id) {
                return Err("server ids must be unique".into());
            }
            if server.name.trim().is_empty() {
                return Err(format!("server {} has an empty name", server.id));
            }
            if server.ssh_host.is_empty()
                || !server
                    .ssh_host
                    .chars()
                    .all(|c| c.is_alphanumeric() || matches!(c, '.' | ':' | '-'))
            {
                return Err(format!("server {} has an invalid SSH host", server.id));
            }
            if server.ssh_user.is_empty()
                || !server
                    .ssh_user
                    .chars()
                    .all(|c| c.is_alphanumeric() || matches!(c, '.' | '_' | '-'))
            {
                return Err(format!("server {} has an invalid SSH user", server.id));
            }
            if server.interval_sec < 5 || server.interval_sec > 3600 {
                return Err(format!("server {} intervalSec must be 5..3600", server.id));
            }
            if server.ssh_key.trim().is_empty() {
                return Err(format!("server {} sshKey must not be empty", server.id));
            }
            if server.public_urls.iter().any(|url| {
                !(url.starts_with("https://") || url.starts_with("http://"))
                    || url.chars().any(char::is_whitespace)
            }) {
                return Err(format!(
                    "server {} contains an invalid public URL",
                    server.id
                ));
            }
            if server.cert_hosts.iter().any(|host| {
                host.is_empty()
                    || !host
                        .chars()
                        .all(|c| c.is_alphanumeric() || matches!(c, '.' | '-'))
            }) {
                return Err(format!(
                    "server {} contains an invalid certificate host",
                    server.id
                ));
            }
        }

        let alerts = &self.alerts;
        for (name, value) in [
            ("alerts.diskPct", alerts.disk_pct),
            ("alerts.memPct", alerts.mem_pct),
            ("alerts.cpuPct", alerts.cpu_pct),
        ] {
            if !value.is_finite() || !(1.0..=100.0).contains(&value) {
                return Err(format!("{name} must be between 1 and 100"));
            }
        }
        if alerts.health_max_fails == 0 || alerts.backup_max_age_hours == 0 {
            return Err("healthMaxFails and backupMaxAgeHours must be at least 1".into());
        }

        let collection = &self.collection;
        if !(10..=86_400).contains(&collection.full_interval_sec) {
            return Err("collection.fullIntervalSec must be 10..86400".into());
        }
        if !(5..=300).contains(&collection.timeout_sec) {
            return Err("collection.timeoutSec must be 5..300".into());
        }
        if !(1..=3650).contains(&collection.retention_days) {
            return Err("collection.retentionDays must be 1..3650".into());
        }
        if !(5..=3600).contains(&collection.backoff_max_sec) {
            return Err("collection.backoffMaxSec must be 5..3600".into());
        }
        Ok(())
    }
}

struct ProtectedConfigStore {
    bundled_path: PathBuf,
    local_path: PathBuf,
}

impl ProtectedConfigStore {
    fn open(app: &tauri::App) -> Result<Self, String> {
        let resource_dir = app
            .path()
            .resource_dir()
            .map_err(|error| format!("cannot resolve application resources: {error}"))?;
        let app_data = app
            .path()
            .app_data_dir()
            .map_err(|error| format!("cannot resolve application data directory: {error}"))?;
        fs::create_dir_all(&app_data)
            .map_err(|error| format!("cannot create application data directory: {error}"))?;
        Ok(Self {
            bundled_path: resource_dir.join(CONFIG_FILE),
            local_path: app_data.join(CONFIG_FILE),
        })
    }

    fn backup_path(&self) -> PathBuf {
        self.local_path.with_extension("dpapi.bak")
    }

    fn load(&self) -> Result<MonitorConfig, String> {
        if self.local_path.is_file() {
            match Self::decrypt_file(&self.local_path) {
                Ok(config) => return Ok(config),
                Err(primary_error) => {
                    let backup = self.backup_path();
                    if backup.is_file() {
                        if let Ok(config) = Self::decrypt_file(&backup) {
                            fs::copy(&backup, &self.local_path).map_err(|error| {
                                format!(
                                    "configuration backup is valid but cannot be restored: {error}"
                                )
                            })?;
                            return Ok(config);
                        }
                    }
                    return Err(format!(
                        "protected configuration cannot be decrypted for this Windows user: {primary_error}"
                    ));
                }
            }
        }

        let config = Self::decrypt_file(&self.bundled_path).map_err(|error| {
            format!("bundled protected configuration is unavailable or belongs to another Windows user: {error}")
        })?;
        let cipher = fs::read(&self.bundled_path)
            .map_err(|error| format!("cannot read bundled protected configuration: {error}"))?;
        self.write_cipher(&cipher)?;
        Ok(config)
    }

    fn decrypt_file(path: &Path) -> Result<MonitorConfig, String> {
        let cipher = fs::read(path).map_err(|error| format!("cannot read ciphertext: {error}"))?;
        let mut plain = protected_data::unprotect(&cipher)
            .map_err(|error| format!("DPAPI rejected ciphertext: {error}"))?;
        let decoded = serde_json::from_slice::<MonitorConfig>(&plain)
            .map_err(|error| format!("decrypted configuration is invalid: {error}"));
        plain.fill(0);
        let config = decoded?;
        config.validate()?;
        Ok(config)
    }

    fn save(&self, config: &MonitorConfig) -> Result<(), String> {
        config.validate()?;
        let mut plain = serde_json::to_vec(config)
            .map_err(|error| format!("cannot encode configuration: {error}"))?;
        let protected = protected_data::protect(&plain)
            .map_err(|error| format!("cannot protect configuration with DPAPI: {error}"));
        plain.fill(0);
        self.write_cipher(&protected?)
    }

    fn write_cipher(&self, cipher: &[u8]) -> Result<(), String> {
        let parent = self
            .local_path
            .parent()
            .ok_or_else(|| "configuration path has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create configuration directory: {error}"))?;
        let temp = parent.join(format!(".{CONFIG_FILE}.{}.tmp", std::process::id()));
        let result = (|| {
            let mut file = fs::File::create(&temp)
                .map_err(|error| format!("cannot create temporary configuration: {error}"))?;
            use std::io::Write;
            file.write_all(cipher)
                .map_err(|error| format!("cannot write temporary configuration: {error}"))?;
            file.sync_all()
                .map_err(|error| format!("cannot flush temporary configuration: {error}"))?;
            if self.local_path.is_file() {
                fs::copy(&self.local_path, self.backup_path())
                    .map_err(|error| format!("cannot preserve configuration backup: {error}"))?;
            }
            move_replace(&temp, &self.local_path)
                .map_err(|error| format!("cannot replace protected configuration: {error}"))
        })();
        if temp.exists() {
            let _ = fs::remove_file(temp);
        }
        result
    }
}

#[cfg(windows)]
fn move_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let source_wide: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination_wide: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let moved = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
fn move_replace(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[derive(Serialize, Clone)]
struct BackendInfo {
    port: u16,
    token: String,
}

struct BackendState {
    info: Mutex<Option<BackendInfo>>,
    error: Mutex<Option<String>>,
    child: Mutex<Option<CommandChild>>,
    #[cfg(windows)]
    job: Mutex<Option<process_job::ProcessJob>>,
}

#[tauri::command]
fn get_backend_info(state: State<'_, BackendState>) -> Result<BackendInfo, String> {
    if let Some(info) = state
        .info
        .lock()
        .map_err(|_| "backend state lock poisoned".to_string())?
        .clone()
    {
        return Ok(info);
    }
    Err(state
        .error
        .lock()
        .map_err(|_| "backend error lock poisoned".to_string())?
        .clone()
        .unwrap_or_else(|| "backend not ready".into()))
}

#[tauri::command]
fn get_monitor_config(state: State<'_, ProtectedConfigStore>) -> Result<MonitorConfig, String> {
    state.load()
}

#[tauri::command]
fn save_monitor_config(
    config: MonitorConfig,
    state: State<'_, ProtectedConfigStore>,
) -> Result<(), String> {
    state.save(&config)
}

fn set_backend_error(state: &BackendState, message: String) {
    if let Ok(mut error) = state.error.lock() {
        *error = Some(message);
    }
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
            error: Mutex::new(None),
            child: Mutex::new(None),
            #[cfg(windows)]
            job: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            get_backend_info,
            get_monitor_config,
            save_monitor_config
        ])
        .setup(|app| {
            let config_store = ProtectedConfigStore::open(app)?;
            let config_result = config_store.load();
            app.manage(config_store);

            let config = match config_result {
                Ok(config) => config,
                Err(error) => {
                    set_backend_error(&app.state::<BackendState>(), error);
                    return Ok(());
                }
            };
            let config_dir = app
                .path()
                .app_data_dir()
                .map_err(|error| format!("cannot resolve configuration base directory: {error}"))?;
            let mut config_json = serde_json::to_string(&config)
                .map_err(|error| format!("cannot encode sidecar configuration: {error}"))?;
            let token: String = rand::thread_rng()
                .sample_iter(&Alphanumeric)
                .take(32)
                .map(char::from)
                .collect();

            let state = app.state::<BackendState>();
            let sidecar = app
                .shell()
                .sidecar("monitor-backend")
                .map_err(|error| format!("sidecar resolve: {error}"))?;
            let (mut rx, child) = sidecar
                .env("SERVER_MONITOR_CONFIG_JSON", &config_json)
                .env("SERVER_MONITOR_CONFIG_DIR", &config_dir)
                .env("SERVER_MONITOR_AUTH_TOKEN", &token)
                .spawn()
                .map_err(|error| format!("sidecar spawn: {error}"))?;
            // The command builder has copied the environment. Remove the
            // plaintext JSON from this allocation as soon as the child exists.
            unsafe { config_json.as_bytes_mut().fill(0) };

            #[cfg(windows)]
            {
                let job = process_job::ProcessJob::new()
                    .map_err(|error| format!("sidecar job create: {error}"))?;
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

            let expected_token = token;
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                while let Some(event) = rx.recv().await {
                    match event {
                        CommandEvent::Stdout(line) => {
                            let text = String::from_utf8_lossy(&line);
                            if let Some(rest) = text.strip_prefix("READY ") {
                                let mut parts = rest.trim().splitn(2, ' ');
                                if let (Some(port_s), Some(returned_token)) =
                                    (parts.next(), parts.next())
                                {
                                    if returned_token == expected_token {
                                        if let Ok(port) = port_s.parse::<u16>() {
                                            if let Some(state) =
                                                app_handle.try_state::<BackendState>()
                                            {
                                                if let Ok(mut info) = state.info.lock() {
                                                    *info = Some(BackendInfo {
                                                        port,
                                                        token: expected_token.clone(),
                                                    });
                                                    if let Ok(mut error) = state.error.lock() {
                                                        *error = None;
                                                    }
                                                    let _ = app_handle.emit("backend-ready", ());
                                                }
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
                            if let Some(state) = app_handle.try_state::<BackendState>() {
                                set_backend_error(
                                    &state,
                                    format!("sidecar process error: {error}"),
                                );
                            }
                        }
                        CommandEvent::Terminated(payload) => {
                            if let Some(state) = app_handle.try_state::<BackendState>() {
                                if let Ok(mut info) = state.info.lock() {
                                    *info = None;
                                }
                                if let Ok(mut child) = state.child.lock() {
                                    *child = None;
                                }
                                #[cfg(windows)]
                                if let Ok(mut job) = state.job.lock() {
                                    *job = None;
                                }
                                set_backend_error(
                                    &state,
                                    format!("backend exited with code {:?}", payload.code),
                                );
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
                if let Some(state) = window.app_handle().try_state::<BackendState>() {
                    if let Ok(mut child_slot) = state.child.lock() {
                        if let Some(child) = child_slot.take() {
                            let _ = child.kill();
                        }
                    }
                    #[cfg(windows)]
                    if let Ok(mut job_slot) = state.job.lock() {
                        *job_slot = None;
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
