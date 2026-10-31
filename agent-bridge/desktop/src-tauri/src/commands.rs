use crate::runtime::{self, native_error, service, AppState};
use agentd::{
    types::{AppSettings, PairSession, Snapshot},
    Result,
};
use serde::Serialize;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
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
pub async fn open_pairing(app: AppHandle) -> Result<()> {
    service(&app).await?;
    if let Some(window) = app.get_webview_window("pairing") {
        window
            .show()
            .map_err(|_| native_error("无法显示配对窗口。"))?;
        window
            .set_focus()
            .map_err(|_| native_error("无法聚焦配对窗口。"))?;
    } else {
        WebviewWindowBuilder::new(
            &app,
            "pairing",
            WebviewUrl::App("index.html?pairing".into()),
        )
        .title("配对新设备 · Agent Bridge")
        .inner_size(360.0, 520.0)
        .resizable(false)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .center()
        .on_navigation(|url| {
            url.scheme() == "tauri"
                || url.host_str().is_some_and(|host| {
                    matches!(host, "localhost" | "tauri.localhost" | "127.0.0.1")
                })
        })
        .build()
        .map_err(|_| native_error("无法打开配对窗口。"))?;
    }
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.hide();
    }
    Ok(())
}

#[tauri::command]
pub async fn start_pairing(app: AppHandle, window: WebviewWindow) -> Result<PairSession> {
    if window.label() != "pairing" {
        return Err(native_error("请在配对窗口生成邀请。"));
    }
    let state = app.state::<AppState>();
    let mut invitation = state.invitation.lock().await;
    // Repeated IPC requests share one window-owned invitation, including React StrictMode.
    if let Some(session) = invitation.as_ref() {
        return Ok(session.clone());
    }
    let session = service(&app).await?.start_pairing().await?;
    *invitation = Some(session.clone());
    Ok(session)
}
#[tauri::command]
pub async fn cancel_pairing(app: AppHandle, session_id: String) -> Result<()> {
    service(&app).await?.cancel_pairing(&session_id).await
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
pub async fn close_pairing(app: AppHandle) -> Result<()> {
    let state = app.state::<AppState>();
    let mut invitation = state.invitation.lock().await;
    if let Some(session) = invitation.as_ref() {
        if let Some(daemon) = state.daemon.read().await.as_ref() {
            if let Err(error) = daemon.cancel_pairing(&session.session_id).await {
                // A replaced invitation is already invalid; do not cancel its successor.
                // Other failures keep the current window/cache intact for an explicit retry.
                if error.code != "conflict" {
                    return Err(error);
                }
            }
        }
    }
    *invitation = None;
    drop(invitation);
    if let Some(window) = app.get_webview_window("pairing") {
        window
            .destroy()
            .map_err(|_| native_error("无法关闭配对窗口。"))?;
    }
    Ok(())
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
