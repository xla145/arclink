use agentd::{network::NetworkServer, BridgeError, Daemon, Result};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::{Mutex, RwLock};

#[derive(Default)]
pub struct AppState {
    pub daemon: RwLock<Option<Arc<Daemon>>>,
    pub network: Mutex<Option<NetworkServer>>,
    pub startup_error: RwLock<Option<BridgeError>>,
    pub initializing: AtomicBool,
    pub stopping: AtomicBool,
    pub shutdown_inflight: AtomicBool,
    pub lifecycle: Mutex<()>,
    pub exit_allowed: AtomicBool,
    pub invitation: Mutex<Option<agentd::types::PairSession>>,
}

pub fn native_error(message: &str) -> BridgeError {
    BridgeError::new("native_error", message)
}

pub fn protect_log_directory(
    app: &AppHandle,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let directory = app.path().app_log_dir()?;
    std::fs::create_dir_all(&directory)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        for entry in std::fs::read_dir(&directory)? {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                std::fs::set_permissions(entry.path(), std::fs::Permissions::from_mode(0o600))?;
            }
        }
    }
    Ok(())
}

pub async fn service(app: &AppHandle) -> Result<Arc<Daemon>> {
    let state = app.state::<AppState>();
    if state.stopping.load(Ordering::SeqCst) {
        return Err(BridgeError::new("unavailable", "服务正在退出，请稍候。"));
    }
    if let Some(daemon) = state.daemon.read().await.clone() {
        return Ok(daemon);
    }
    let error = state
        .startup_error
        .read()
        .await
        .clone()
        .unwrap_or_else(|| BridgeError::new("starting", "本机服务正在启动，请稍候。"));
    Err(error)
}

pub async fn initialize(app: AppHandle) {
    let state = app.state::<AppState>();
    if state.stopping.load(Ordering::SeqCst) || state.initializing.swap(true, Ordering::SeqCst) {
        return;
    }
    let result = initialize_inner(&app).await;
    if state.stopping.load(Ordering::SeqCst) {
        state.initializing.store(false, Ordering::SeqCst);
        return;
    }
    if let Err(error) = result {
        log::warn!("Host initialization failed ({})", error.code);
        *state.startup_error.write().await = Some(error.clone());
        if let Some(daemon) = state.daemon.read().await.as_ref() {
            daemon.set_network("error", None, Some(error.message));
        }
    } else {
        *state.startup_error.write().await = None;
        log::info!("Embedded host initialized");
    }
    state.initializing.store(false, Ordering::SeqCst);
    let _ = app.emit("bridge-changed", ());
}

async fn initialize_inner(app: &AppHandle) -> Result<()> {
    let state = app.state::<AppState>();
    let existing = state.daemon.read().await.clone();
    let daemon = if let Some(daemon) = existing {
        daemon
    } else {
        let data_dir = app
            .path()
            .app_data_dir()
            .map_err(|_| native_error("无法定位应用数据目录。"))?;
        let daemon = tokio::task::spawn_blocking(move || Daemon::open(data_dir))
            .await
            .map_err(|_| native_error("本机服务初始化失败。"))??;
        let lifecycle = state.lifecycle.lock().await;
        if state.stopping.load(Ordering::SeqCst) {
            return Ok(());
        }
        let mut events = daemon.subscribe();
        *state.daemon.write().await = Some(daemon.clone());
        drop(lifecycle);
        let event_app = app.clone();
        let event_daemon = daemon.clone();
        tauri::async_runtime::spawn(async move {
            while let Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) =
                events.recv().await
            {
                if let Ok(snapshot) = event_daemon.snapshot().await {
                    if matches!(
                        snapshot.pairing.state.as_str(),
                        "approved" | "rejected" | "expired" | "cancelled"
                    ) {
                        let state = event_app.state::<AppState>();
                        let mut invitation = state.invitation.lock().await;
                        if invitation.as_ref().is_some_and(|session| {
                            snapshot.pairing.session_id.as_deref()
                                == Some(session.session_id.as_str())
                        }) {
                            *invitation = None;
                        }
                    }
                    let _ = event_app.emit("bridge-snapshot", snapshot);
                }
            }
        });
        let discovery = daemon.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(error) = discovery.list_agents(false).await {
                log::warn!("Agent discovery failed ({})", error.code);
            }
        });
        daemon
    };
    if state.network.lock().await.is_some() {
        return Ok(());
    }
    #[cfg(all(debug_assertions, unix))]
    let identity_loader = {
        let directory = app
            .path()
            .app_data_dir()
            .map_err(|_| native_error("无法定位开发身份目录。"))?;
        move || agentd::identity::load_or_create_development(&directory)
    };
    #[cfg(not(all(debug_assertions, unix)))]
    let identity_loader = agentd::identity::load_or_create;
    let identity = tokio::task::spawn_blocking(identity_loader)
        .await
        .map_err(|_| native_error("系统凭据存储暂不可用。"))??;
    let _lifecycle = state.lifecycle.lock().await;
    if state.stopping.load(Ordering::SeqCst) {
        return Ok(());
    }
    let credential_app = app.clone();
    let settings =
        tokio::task::spawn_blocking(move || crate::network_settings::load(&credential_app))
            .await
            .map_err(|_| native_error("无法读取中继配置。"))??;
    let network = settings.network()?;
    if let Some(url) = &network.hints.relay_url {
        log::info!("Configured relay: {}", url);
    } else {
        log::info!("Using default public relays");
    }
    let server = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        NetworkServer::start_with_network(daemon, identity, true, &network),
    )
    .await
    .map_err(|_| native_error("网络服务启动超时，请检查网络后重试。"))??;
    *state.network.lock().await = Some(server);
    Ok(())
}

pub async fn request_shutdown(app: AppHandle, confirmed: bool) -> Result<()> {
    let state = app.state::<AppState>();
    if state.shutdown_inflight.load(Ordering::SeqCst) {
        return Ok(());
    }
    if !confirmed {
        // Always confirm: a remote start could race an idle-count check.
        crate::tray::show_panel(&app, None);
        app.emit("confirm-exit", ())
            .map_err(|_| native_error("无法打开退出确认，请从设置重试。"))?;
        return Ok(());
    }
    stop_owned_host(&app).await?;
    state.exit_allowed.store(true, Ordering::SeqCst);
    app.exit(0);
    Ok(())
}

// Keep shutdown ownership until install/restart completes, so Quit cannot race
// replacement of the app bundle. Failed cleanup permits a later explicit retry.
pub async fn stop_for_update(app: &AppHandle) -> Result<()> {
    stop_owned_host(app).await
}

async fn stop_owned_host(app: &AppHandle) -> Result<()> {
    let state = app.state::<AppState>();
    let lifecycle = state.lifecycle.lock().await;
    if state.shutdown_inflight.swap(true, Ordering::SeqCst) {
        return Err(BridgeError::new(
            "shutdown_busy",
            "应用正在退出或安装更新，请稍候。",
        ));
    }
    state.stopping.store(true, Ordering::SeqCst);
    if let Err(error) = app
        .state::<crate::keep_awake::KeepAwake>()
        .0
        .lock()
        .unwrap()
        .stop()
    {
        state.shutdown_inflight.store(false, Ordering::SeqCst);
        return Err(error);
    }
    let daemon = state.daemon.read().await.clone();
    drop(lifecycle);
    if let Some(daemon) = daemon {
        if let Err(error) = daemon.shutdown().await {
            // Keep mutation access disabled; a subsequent explicit exit can retry cleanup.
            state.shutdown_inflight.store(false, Ordering::SeqCst);
            return Err(error);
        }
    }
    if let Some(network) = state.network.lock().await.take() {
        // iroh can stall in close(); don't leave Quit hanging on it.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(3), network.shutdown()).await;
    }
    log::info!("Owned host stopped");
    Ok(())
}
