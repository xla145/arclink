//! Only native code can select a release, verify bytes, or install. The WebView
//! receives status and supplies consent, never a URL, path, signature or key.
use crate::runtime::{self, AppState};
use agentd::{BridgeError, Result};
use serde::Serialize;
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{AppHandle, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

#[derive(Clone, Serialize)]
pub struct UpdateStatus {
    revision: String,
    current_version: String,
    phase: String,
    version: Option<String>,
    notes: Option<String>,
    downloaded: u64,
    total: Option<u64>,
    error: Option<BridgeError>,
    restart_required: bool,
}
impl Default for UpdateStatus {
    fn default() -> Self {
        Self {
            revision: "0".into(),
            current_version: env!("CARGO_PKG_VERSION").into(),
            phase: "idle".into(),
            version: None,
            notes: None,
            downloaded: 0,
            total: None,
            error: None,
            restart_required: false,
        }
    }
}
#[derive(Default)]
struct Inner {
    status: UpdateStatus,
    candidate: Option<Update>,
    bytes: Option<Arc<Vec<u8>>>,
    startup_checked: bool,
    revision: u64,
}
impl Inner {
    fn changed(&mut self) -> UpdateStatus {
        self.revision += 1;
        self.status.revision = self.revision.to_string();
        self.status.clone()
    }
    fn require_idle(&self) -> Result<()> {
        if matches!(
            self.status.phase.as_str(),
            "checking" | "downloading" | "installing"
        ) {
            Err(BridgeError::new(
                "update_busy",
                "更新操作正在进行，请稍候。",
            ))
        } else {
            Ok(())
        }
    }
    fn require_version(&self, version: &str) -> Result<Update> {
        self.candidate
            .as_ref()
            .filter(|update| update.version == version)
            .cloned()
            .ok_or_else(|| BridgeError::new("update_changed", "版本已变化，请重新检查更新。"))
    }
}
#[derive(Default)]
pub struct UpdateState(Mutex<Inner>);

fn edit<T>(app: &AppHandle, f: impl FnOnce(&mut Inner) -> T) -> T {
    // No user code runs with this short, synchronous state lock held.
    f(&mut app
        .state::<UpdateState>()
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner()))
}
fn failed(app: &AppHandle, code: &str, message: &str, restart_required: bool) {
    edit(app, |inner| {
        inner.status.phase = "error".into();
        inner.status.error = Some(BridgeError::new(code, message));
        inner.status.restart_required = restart_required;
        inner.changed();
    });
}

#[tauri::command]
pub fn get_update_status(app: AppHandle) -> UpdateStatus {
    edit(&app, |inner| inner.status.clone())
}

#[tauri::command]
pub fn check_for_update(app: AppHandle, startup: bool) -> Result<UpdateStatus> {
    let start = edit(&app, |inner| -> Result<Option<UpdateStatus>> {
        if startup && inner.startup_checked {
            return Ok(None);
        }
        inner.require_idle()?;
        if inner.status.restart_required {
            return Err(BridgeError::new(
                "restart_required",
                "本机服务已停止，请重试安装或退出后重新打开应用。",
            ));
        }
        inner.startup_checked = true;
        inner.candidate = None;
        inner.bytes = None;
        inner.status.phase = "checking".into();
        inner.status.version = None;
        inner.status.notes = None;
        inner.status.error = None;
        inner.status.downloaded = 0;
        inner.status.total = None;
        Ok(Some(inner.changed()))
    })?;
    let Some(status) = start else {
        return Ok(get_update_status(app));
    };
    tauri::async_runtime::spawn(async move {
        let result = async {
            app.updater_builder()
                .timeout(Duration::from_secs(20))
                .restart_after_install(false)
                .build()?
                .check()
                .await
        }
        .await;
        match result {
            Ok(candidate) => {
                // Require encrypted transport even though the plugin only warns for archives.
                if candidate
                    .as_ref()
                    .is_some_and(|update| update.download_url.scheme() != "https")
                {
                    failed(
                        &app,
                        "update_transport",
                        "更新下载地址不安全，已拒绝此更新。",
                        false,
                    );
                    return;
                }
                edit(&app, |inner| {
                    inner.status.phase = if candidate.is_some() {
                        "available"
                    } else {
                        "current"
                    }
                    .into();
                    inner.status.version = candidate.as_ref().map(|u| u.version.clone());
                    inner.status.notes = candidate.as_ref().and_then(|u| u.body.clone());
                    inner.candidate = candidate;
                    inner.changed();
                });
            }
            Err(_) => failed(
                &app,
                "update_check_failed",
                "无法检查更新，请检查网络后重试。",
                false,
            ),
        }
    });
    Ok(status)
}

#[tauri::command]
pub fn download_update(app: AppHandle, version: String) -> Result<UpdateStatus> {
    let (mut update, status) = edit(&app, |inner| -> Result<_> {
        inner.require_idle()?;
        if inner.status.restart_required {
            return Err(BridgeError::new(
                "restart_required",
                "请重试安装或退出后重新打开应用。",
            ));
        }
        let update = inner.require_version(&version)?;
        inner.bytes = None;
        inner.status.phase = "downloading".into();
        inner.status.error = None;
        inner.status.downloaded = 0;
        inner.status.total = None;
        Ok((update, inner.changed()))
    })?;
    update.timeout = Some(Duration::from_secs(600));
    tauri::async_runtime::spawn(async move {
        let progress_app = app.clone();
        let downloaded = update
            .download(
                move |chunk, total| {
                    edit(&progress_app, |inner| {
                        inner.status.downloaded =
                            inner.status.downloaded.saturating_add(chunk as u64);
                        inner.status.total = total;
                        inner.changed();
                    });
                },
                || {},
            )
            .await;
        match downloaded {
            Ok(bytes) => edit(&app, |inner| {
                inner.bytes = Some(Arc::new(bytes));
                inner.status.phase = "ready".into();
                inner.changed();
            }),
            Err(_) => failed(
                &app,
                "update_download_failed",
                "更新下载或签名校验失败，应用未被修改。请重新下载。",
                false,
            ),
        }
    });
    Ok(status)
}

#[tauri::command]
pub fn install_update(app: AppHandle, version: String, confirmed: bool) -> Result<UpdateStatus> {
    if !confirmed {
        return Err(BridgeError::new(
            "confirmation_required",
            "请确认安装更新并停止所有 Agent 任务。",
        ));
    }
    let (update, bytes, status) = edit(&app, |inner| -> Result<_> {
        inner.require_idle()?;
        let update = inner.require_version(&version)?;
        let bytes = inner
            .bytes
            .clone()
            .ok_or_else(|| BridgeError::new("update_not_downloaded", "请先下载并验证更新。"))?;
        inner.status.phase = "installing".into();
        inner.status.error = None;
        Ok((update, bytes, inner.changed()))
    })?;
    tauri::async_runtime::spawn(async move {
        // Check again immediately before touching the running host. install() also verifies.
        if update.verify(bytes.as_slice()).is_err() {
            failed(
                &app,
                "update_signature",
                "更新签名校验失败，应用未被修改。",
                false,
            );
            return;
        }
        if let Err(error) = runtime::stop_for_update(&app).await {
            let stopped = app
                .state::<AppState>()
                .stopping
                .load(std::sync::atomic::Ordering::SeqCst);
            failed(&app, &error.code, &error.message, stopped);
            return;
        }
        let result = tokio::task::spawn_blocking(move || update.install(bytes.as_slice())).await;
        if !matches!(result, Ok(Ok(()))) {
            app.state::<AppState>()
                .shutdown_inflight
                .store(false, std::sync::atomic::Ordering::SeqCst);
            failed(
                &app,
                "update_install_failed",
                "安装失败，本机服务已停止。请重试安装，或退出后重新打开应用。",
                true,
            );
            return;
        }
        app.state::<AppState>()
            .exit_allowed
            .store(true, std::sync::atomic::Ordering::SeqCst);
        app.restart();
    });
    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn in_flight_operations_reject_duplicates_but_errors_allow_explicit_retry() {
        let mut inner = Inner::default();
        for phase in ["checking", "downloading", "installing"] {
            inner.status.phase = phase.into();
            assert_eq!(inner.require_idle().unwrap_err().code, "update_busy");
        }
        inner.status.phase = "error".into();
        assert!(inner.require_idle().is_ok());
    }
    #[test]
    fn revision_is_serialized_as_string_and_errors_are_not_current() {
        let mut inner = Inner::default();
        inner.status.phase = "error".into();
        inner.status.error = Some(BridgeError::new("update_check_failed", "offline"));
        let value = serde_json::to_value(inner.changed()).unwrap();
        assert_eq!(value["revision"], "1");
        assert_eq!(value["phase"], "error");
        assert_eq!(value["error"]["code"], "update_check_failed");
        assert!(inner.require_version("9.9.9").is_err());
    }
}

#[cfg(test)]
#[path = "updater_endpoint_tests.rs"]
mod endpoint_tests;
