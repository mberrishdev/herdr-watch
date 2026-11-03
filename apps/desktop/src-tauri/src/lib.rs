use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_shell::{process::{CommandChild, CommandEvent}, ShellExt};

#[derive(Default)]
struct RelayProcess(Mutex<Option<CommandChild>>);

#[derive(Deserialize)]
struct PairingReply { pairing_code: String }

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayStatus { configured: bool, endpoint: Option<String> }

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SshReadiness { open_ssh_installed: bool, sshd_running: bool, firewall_ready: bool, herdr_available: bool }

#[tauri::command]
fn ssh_readiness() -> Result<SshReadiness, String> {
    #[cfg(windows)]
    {
        let script = r#"
$capability = (Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue).State -eq 'Installed'
$service = Get-Service -Name sshd -ErrorAction SilentlyContinue
$firewall = @(Get-NetFirewallRule -DisplayGroup 'OpenSSH Server' -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True').Count -gt 0
$herdr = $null -ne (Get-Command herdr -ErrorAction SilentlyContinue)
[PSCustomObject]@{ open_ssh_installed = $capability; sshd_running = ($null -ne $service -and $service.Status -eq 'Running'); firewall_ready = $firewall; herdr_available = $herdr } | ConvertTo-Json -Compress
"#;
        let output = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .output()
            .map_err(err)?;
        if !output.status.success() { return Err(stderr_message(&output.stderr)); }
        return serde_json::from_slice(&output.stdout).map_err(err);
    }
    #[cfg(not(windows))]
    {
        Err("Windows SSH checks are only available on Windows.".into())
    }
}

#[tauri::command]
async fn relay_status(app: AppHandle) -> Result<RelayStatus, String> {
    let output = app.shell().sidecar("herdrwatch-host").map_err(err)?.args(["relay", "status", "--json"]).output().await.map_err(err)?;
    if !output.status.success() { return Err(stderr_message(&output.stderr)); }
    let raw: RelayStatus = serde_json::from_slice(&output.stdout).map_err(err)?;
    Ok(raw)
}

#[tauri::command]
async fn create_pairing(app: AppHandle, endpoint: String) -> Result<String, String> {
    let endpoint = endpoint.trim();
    let parsed = endpoint.strip_prefix("wss://").ok_or("Use a secure relay address beginning with wss://.")?;
    if parsed.is_empty() || parsed.contains('@') || parsed.contains('?') || parsed.contains('#') {
        return Err("Enter a valid secure relay address.".into());
    }
    let output = app.shell().sidecar("herdrwatch-host").map_err(err)?.args(["relay", "init", "--endpoint", endpoint, "--json"]).output().await.map_err(err)?;
    if !output.status.success() { return Err(stderr_message(&output.stderr)); }
    let reply: PairingReply = serde_json::from_slice(&output.stdout).map_err(err)?;
    Ok(reply.pairing_code)
}

#[tauri::command]
async fn show_pairing(app: AppHandle) -> Result<String, String> {
    let output = app.shell().sidecar("herdrwatch-host").map_err(err)?.args(["relay", "pairing-code", "--json"]).output().await.map_err(err)?;
    if !output.status.success() { return Err(stderr_message(&output.stderr)); }
    let reply: PairingReply = serde_json::from_slice(&output.stdout).map_err(err)?;
    Ok(reply.pairing_code)
}

#[tauri::command]
async fn start_relay(app: AppHandle, process: State<'_, RelayProcess>) -> Result<(), String> {
    let mut current = process.0.lock().map_err(err)?;
    if current.is_some() { return Ok(()); }
    let (mut events, child) = app.shell().sidecar("herdrwatch-host").map_err(err)?.args(["relay", "run"]).spawn().map_err(err)?;
    *current = Some(child);
    drop(current);
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            let (kind, bytes) = match event {
                CommandEvent::Stdout(data) => ("stdout", data),
                CommandEvent::Stderr(data) => ("stderr", data),
                CommandEvent::Terminated(payload) => {
                    let _ = app.emit("relay-event", format!("terminated:{}", payload.code.unwrap_or(-1)));
                    if let Ok(mut child) = app.state::<RelayProcess>().0.lock() { child.take(); }
                    break;
                }
                _ => continue,
            };
            let text = String::from_utf8_lossy(&bytes).trim().to_owned();
            if !text.is_empty() { let _ = app.emit("relay-event", format!("{kind}:{text}")); }
        }
    });
    Ok(())
}

#[tauri::command]
fn stop_relay(process: State<'_, RelayProcess>) -> Result<(), String> {
    if let Some(child) = process.0.lock().map_err(err)?.take() { child.kill().map_err(err)?; }
    Ok(())
}

fn stderr_message(stderr: &[u8]) -> String {
    let message = String::from_utf8_lossy(stderr).trim().to_string();
    if message.is_empty() { "The host companion could not complete that request.".into() } else { message }
}

fn err(error: impl std::fmt::Display) -> String { error.to_string() }

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(RelayProcess::default())
        .invoke_handler(tauri::generate_handler![relay_status, ssh_readiness, create_pairing, show_pairing, start_relay, stop_relay])
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                if let Some(process) = window.try_state::<RelayProcess>() {
                    if let Ok(mut child) = process.0.lock() {
                        if let Some(child) = child.take() { let _ = child.kill(); }
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running HerdrWatch Host manager");
}
