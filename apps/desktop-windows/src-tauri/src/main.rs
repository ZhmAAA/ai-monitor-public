#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use std::{
    env, fs,
    net::{SocketAddr, TcpStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::Mutex,
    time::Duration,
};
use tauri::{AppHandle, Manager, State};

const DEFAULT_CONFIG: &str = include_str!("../../../../config/default.toml");

struct DaemonState {
    child: Mutex<Option<Child>>,
}

#[derive(Debug, Serialize)]
struct DaemonStatus {
    online: bool,
    managed: bool,
    pid: Option<u32>,
    message: String,
}

#[derive(Debug, Serialize)]
struct AppPaths {
    data_dir: String,
    config_file: String,
    database_file: String,
    token_file: String,
    log_dir: String,
}

#[derive(Debug, Clone)]
struct RuntimePaths {
    data_dir: PathBuf,
    config_file: PathBuf,
    database_file: PathBuf,
    token_file: PathBuf,
    log_dir: PathBuf,
}

#[tauri::command]
fn daemon_status(state: State<'_, DaemonState>) -> DaemonStatus {
    current_daemon_status(&state)
}

#[tauri::command]
fn start_daemon(app: AppHandle, state: State<'_, DaemonState>) -> Result<DaemonStatus, String> {
    if daemon_port_online() {
        return Ok(DaemonStatus {
            online: true,
            managed: false,
            pid: None,
            message: "Daemon already online".to_string(),
        });
    }

    let executable = resolve_daemon_executable(&app)?;
    let paths = ensure_runtime_paths(&app)?;
    let stdout = fs::File::create(paths.log_dir.join("daemon.out.log")).map_err(to_string)?;
    let stderr = fs::File::create(paths.log_dir.join("daemon.err.log")).map_err(to_string)?;

    let mut command = Command::new(executable);
    command
        .arg("--bind")
        .arg("127.0.0.1:4318")
        .arg("--database")
        .arg(&paths.database_file)
        .arg("--config")
        .arg(&paths.config_file)
        .arg("--api-token-file")
        .arg(&paths.token_file)
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }

    let child = command.spawn().map_err(to_string)?;
    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|_| "Daemon state lock failed")?;
        *guard = Some(child);
    }

    std::thread::sleep(Duration::from_millis(700));
    Ok(DaemonStatus {
        online: daemon_port_online(),
        managed: true,
        pid: Some(pid),
        message: "Daemon started".to_string(),
    })
}

#[tauri::command]
fn stop_daemon(state: State<'_, DaemonState>) -> Result<DaemonStatus, String> {
    let mut guard = state.child.lock().map_err(|_| "Daemon state lock failed")?;
    if let Some(mut child) = guard.take() {
        child.kill().map_err(to_string)?;
        let _ = child.wait();
        return Ok(DaemonStatus {
            online: daemon_port_online(),
            managed: false,
            pid: None,
            message: "Daemon stopped".to_string(),
        });
    }

    Ok(DaemonStatus {
        online: daemon_port_online(),
        managed: false,
        pid: None,
        message: "No managed daemon is running".to_string(),
    })
}

#[tauri::command]
fn read_api_token(app: AppHandle) -> Result<Option<String>, String> {
    let paths = ensure_runtime_paths(&app)?;
    match fs::read_to_string(paths.token_file) {
        Ok(value) => {
            let token = value.trim().to_string();
            Ok((!token.is_empty()).then_some(token))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

#[tauri::command]
fn app_paths(app: AppHandle) -> Result<AppPaths, String> {
    let paths = ensure_runtime_paths(&app)?;
    Ok(AppPaths {
        data_dir: path_string(paths.data_dir),
        config_file: path_string(paths.config_file),
        database_file: path_string(paths.database_file),
        token_file: path_string(paths.token_file),
        log_dir: path_string(paths.log_dir),
    })
}

#[tauri::command]
fn open_target(target: String) -> Result<(), String> {
    let trimmed = target.trim();
    if trimmed.is_empty() {
        return Err("Target is empty".to_string());
    }
    open::that(trimmed).map_err(to_string)
}

fn current_daemon_status(state: &DaemonState) -> DaemonStatus {
    let mut guard = match state.child.lock() {
        Ok(guard) => guard,
        Err(_) => {
            return DaemonStatus {
                online: daemon_port_online(),
                managed: false,
                pid: None,
                message: "Daemon state lock failed".to_string(),
            };
        }
    };

    if let Some(child) = guard.as_mut() {
        match child.try_wait() {
            Ok(Some(status)) => {
                *guard = None;
                return DaemonStatus {
                    online: daemon_port_online(),
                    managed: false,
                    pid: None,
                    message: format!("Managed daemon exited with {status}"),
                };
            }
            Ok(None) => {
                return DaemonStatus {
                    online: daemon_port_online(),
                    managed: true,
                    pid: Some(child.id()),
                    message: "Managed daemon running".to_string(),
                };
            }
            Err(error) => {
                return DaemonStatus {
                    online: daemon_port_online(),
                    managed: true,
                    pid: Some(child.id()),
                    message: error.to_string(),
                };
            }
        }
    }

    DaemonStatus {
        online: daemon_port_online(),
        managed: false,
        pid: None,
        message: "Daemon status checked".to_string(),
    }
}

fn daemon_port_online() -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], 4318));
    TcpStream::connect_timeout(&address, Duration::from_millis(250)).is_ok()
}

fn ensure_runtime_paths(app: &AppHandle) -> Result<RuntimePaths, String> {
    let data_dir = app.path().app_data_dir().map_err(to_string)?;
    let log_dir = data_dir.join("logs");
    fs::create_dir_all(&log_dir).map_err(to_string)?;

    let config_file = data_dir.join("default.toml");
    if !config_file.exists() {
        fs::write(&config_file, DEFAULT_CONFIG).map_err(to_string)?;
    }

    Ok(RuntimePaths {
        database_file: data_dir.join("ai-monitor.db"),
        token_file: data_dir.join("api-token"),
        data_dir,
        config_file,
        log_dir,
    })
}

fn resolve_daemon_executable(app: &AppHandle) -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("AI_MONITOR_DAEMON_EXE").map(PathBuf::from) {
        if path.exists() {
            return Ok(path);
        }
    }

    let dev_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("target")
        .join("debug")
        .join(executable_name());
    if dev_path.exists() {
        return Ok(dev_path);
    }

    if let Ok(resource_dir) = app.path().resource_dir() {
        for candidate in [
            resource_dir.join(executable_name()),
            resource_dir.join("resources").join(executable_name()),
        ] {
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }

    Err(format!(
        "Could not find {}. Run `npm run daemon:build` first.",
        executable_name()
    ))
}

fn executable_name() -> &'static str {
    if cfg!(windows) {
        "ai-monitor-daemon.exe"
    } else {
        "ai-monitor-daemon"
    }
}

fn path_string(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn to_string(error: impl ToString) -> String {
    error.to_string()
}

fn main() {
    tauri::Builder::default()
        .manage(DaemonState {
            child: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            app_paths,
            daemon_status,
            open_target,
            read_api_token,
            start_daemon,
            stop_daemon
        ])
        .run(tauri::generate_context!())
        .expect("failed to run AI Monitor Windows app");
}
