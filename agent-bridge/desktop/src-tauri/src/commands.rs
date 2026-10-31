use crate::runtime::{self, native_error, service, AppState};
use agentd::{
    types::{AppSettings, PairSession, Snapshot},
    Result,
};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Manager, WebviewWindow};
use tauri_plugin_autostart::ManagerExt;

#[tauri::command]
pub async fn get_snapshot(app: AppHandle) -> Result<Snapshot> {
    service(&app).await?.snapshot().await
}
#[tauri::command]
pub async fn refresh_agents(app: AppHandle) -> Result<()> {
    service(&app).await?.list_agents(true).await?;
    Ok(())
}

#[tauri::command]
pub async fn start_pairing(app: AppHandle, window: WebviewWindow) -> Result<PairSession> {
    if window.label() != "main" {
        return Err(native_error("请在主面板中生成配对邀请。"));
    }
    let state = app.state::<AppState>();
    let mut invitation = state.invitation.lock().await;
    let daemon = service(&app).await?;
    // Retry/StrictMode calls share an active invitation without creating a second session.
    let pairing = daemon.pairing_state().await;
    if let Some(session) = invitation.as_ref() {
        if pairing.session_id.as_deref() == Some(session.session_id.as_str())
            && matches!(pairing.state.as_str(), "waiting" | "pending")
        {
            return Ok(session.clone());
        }
    }
    *invitation = None;
    let mut session = daemon.start_pairing().await?;
    if let Ok(urls) = daemon.open_pair_http().await {
        if let Ok(mut payload) = serde_json::from_str::<serde_json::Value>(&session.qr_payload) {
            payload["pair_urls"] = serde_json::json!(urls);
            if let Ok(text) = serde_json::to_string(&payload) {
                session.qr_payload = text;
            }
        }
    }
    *invitation = Some(session.clone());
    Ok(session)
}
#[tauri::command]
pub async fn cancel_pairing(app: AppHandle, session_id: Option<String>) -> Result<()> {
    let state = app.state::<AppState>();
    let mut invitation = state.invitation.lock().await;
    let target = session_id.or_else(|| {
        invitation
            .as_ref()
            .map(|session| session.session_id.clone())
    });
    if let Some(target) = target {
        // Keep the transient cache intact on failure so explicit cancellation can be retried.
        service(&app).await?.cancel_pairing(&target).await?;
        if invitation
            .as_ref()
            .is_some_and(|session| session.session_id == target)
        {
            *invitation = None;
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn approve_pairing(
    app: AppHandle,
    request_id: String,
    permissions: Vec<String>,
) -> Result<()> {
    service(&app)
        .await?
        .approve_pairing(&request_id, permissions)
        .await?;
    Ok(())
}
#[tauri::command]
pub async fn reject_pairing(app: AppHandle, request_id: String) -> Result<()> {
    service(&app).await?.reject_pairing(&request_id).await
}
#[tauri::command]
pub async fn revoke_device(app: AppHandle, device_id: String) -> Result<()> {
    service(&app).await?.revoke_device(&device_id).await
}
#[tauri::command]
pub async fn update_settings(app: AppHandle, settings: AppSettings) -> Result<()> {
    service(&app).await?.update_settings(settings)
}

#[derive(Serialize)]
pub struct AutostartStatus {
    enabled: bool,
}
#[tauri::command]
pub fn get_autostart(app: AppHandle) -> Result<AutostartStatus> {
    app.autolaunch()
        .is_enabled()
        .map(|enabled| AutostartStatus { enabled })
        .map_err(|_| native_error("无法读取系统登录启动状态。"))
}
#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) -> Result<AutostartStatus> {
    let manager = app.autolaunch();
    if enabled {
        manager.enable()
    } else {
        manager.disable()
    }
    .map_err(|_| native_error("无法修改登录启动，请检查系统设置或查看日志。"))?;
    get_autostart(app)
}
#[tauri::command]
pub async fn open_logs(app: AppHandle) -> Result<()> {
    let path = app
        .path()
        .app_log_dir()
        .map_err(|_| native_error("无法定位日志目录。"))?;
    tokio::task::spawn_blocking(move || {
        std::fs::create_dir_all(&path).map_err(|_| native_error("无法创建日志目录。"))?;
        #[cfg(target_os = "macos")]
        let result = std::process::Command::new("/usr/bin/open")
            .arg(&path)
            .status();
        #[cfg(target_os = "windows")]
        let result = std::process::Command::new("explorer.exe")
            .arg(&path)
            .status();
        #[cfg(target_os = "linux")]
        let result = std::process::Command::new("xdg-open").arg(&path).status();
        result
            .map_err(|_| native_error("无法打开日志目录。"))?
            .success()
            .then_some(())
            .ok_or_else(|| native_error("系统未能打开日志目录。"))
    })
    .await
    .map_err(|_| native_error("打开日志目录失败。"))?
}
#[tauri::command]
pub async fn retry_daemon(app: AppHandle) -> Result<()> {
    runtime::initialize(app).await;
    Ok(())
}
#[tauri::command]
pub fn hide_panel(app: AppHandle) -> Result<()> {
    if let Some(window) = app.get_webview_window("main") {
        window.hide().map_err(|_| native_error("无法隐藏面板。"))?;
    }
    Ok(())
}
#[tauri::command]
pub async fn request_exit(app: AppHandle, confirmed: bool) -> Result<()> {
    runtime::request_shutdown(app, confirmed).await
}
