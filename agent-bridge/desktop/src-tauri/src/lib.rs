mod commands;
mod network_settings;
mod runtime;
mod tray;

use runtime::{initialize, request_shutdown, AppState};
use tauri::{Manager, RunEvent};

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            tray::show_panel(app, None);
        }))
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--background"]),
        ))
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .filter(|metadata| metadata.target().starts_with("agent_bridge_desktop"))
                .max_file_size(1_000_000)
                .rotation_strategy(tauri_plugin_log::RotationStrategy::KeepOne)
                .build(),
        )
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::get_network_settings,
            commands::update_network_settings,
            commands::get_snapshot,
            commands::refresh_agents,
            commands::start_pairing,
            commands::cancel_pairing,
            commands::approve_pairing,
            commands::reject_pairing,
            commands::revoke_device,
            commands::update_settings,
            commands::get_autostart,
            commands::set_autostart,
            commands::open_logs,
            commands::retry_daemon,
            commands::hide_panel,
            commands::request_exit
        ])
        .setup(|app| {
            runtime::protect_log_directory(app.handle())?;
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            tray::install(app.handle())?;
            if !std::env::args().any(|arg| arg == "--background") {
                tray::show_panel(app.handle(), None);
            }
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move { initialize(handle).await });
            Ok(())
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("Could not initialize the desktop shell");
    app.run(|app, event| {
        if let RunEvent::ExitRequested { api, .. } = event {
            let state = app.state::<AppState>();
            if !state.exit_allowed.load(std::sync::atomic::Ordering::SeqCst) {
                api.prevent_exit();
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = request_shutdown(app, false).await {
                        log::warn!("Exit request failed ({})", error.code);
                    }
                });
            }
        }
    });
}

#[cfg(test)]
mod contract_tests {
    #[test]
    fn frontend_fixture_round_trips_through_authoritative_daemon_dto() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../src/test/snapshot-contract.json")).unwrap();
        let snapshot: agentd::types::Snapshot = serde_json::from_value(fixture.clone()).unwrap();
        assert_eq!(serde_json::to_value(&snapshot).unwrap(), fixture);
        assert_eq!(snapshot.revision, "9007199254740993");
        assert!(snapshot.devices[0].last_seen.is_none());
        assert!(fixture.get("token").is_none());
    }
}
