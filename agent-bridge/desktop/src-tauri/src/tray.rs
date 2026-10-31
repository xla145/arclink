use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize,
};

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "打开面板", true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "退出 Agent Bridge", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&open, &settings, &separator, &quit])?;
    TrayIconBuilder::with_id("agent-bridge-tray")
        .icon(tauri::image::Image::from_bytes(include_bytes!(
            "../icons/tray.png"
        ))?)
        .icon_as_template(true)
        .tooltip("Agent Bridge")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_panel(app, None),
            "settings" => {
                show_panel(app, None);
                let _ = app.emit("show-settings", ());
            }
            "quit" => {
                let app = app.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = crate::runtime::request_shutdown(app, false).await {
                        log::warn!("Exit failed ({})", error.code);
                    }
                });
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                position,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false)
                    {
                        let _ = window.hide();
                    } else {
                        show_panel(app, Some(position));
                    }
                }
            }
        })
        .build(app)?;
    Ok(())
}

pub fn show_panel(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let monitor = anchor
        .and_then(|position| {
            window
                .monitor_from_point(position.x, position.y)
                .ok()
                .flatten()
        })
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let scale = monitor.scale_factor();
        let work = monitor.work_area();
        let width = (320.0 * scale).round().min(work.size.width as f64);
        let height = (480.0 * scale).round().min(work.size.height as f64);
        let point = anchor.unwrap_or(PhysicalPosition::new(
            work.position.x as f64 + work.size.width as f64 - width / 2.0,
            work.position.y as f64,
        ));
        let (x, y) = clamp_position(
            point.x - width / 2.0,
            point.y + 12.0 * scale,
            width,
            height,
            work.position.x as f64,
            work.position.y as f64,
            work.size.width as f64,
            work.size.height as f64,
        );
        let _ = window.set_size(PhysicalSize::new(width as u32, height as u32));
        let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
    }
    let _ = window.show();
    let _ = window.set_focus();
}

#[allow(clippy::too_many_arguments)]
fn clamp_position(
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    left: f64,
    top: f64,
    screen_width: f64,
    screen_height: f64,
) -> (f64, f64) {
    (
        x.clamp(left, (left + screen_width - width).max(left)),
        y.clamp(top, (top + screen_height - height).max(top)),
    )
}

#[cfg(test)]
mod tests {
    use super::clamp_position;
    #[test]
    fn panel_stays_on_negative_origin_and_scaled_displays() {
        assert_eq!(
            clamp_position(-2300., 2100., 640., 960., -1920., 40., 1920., 1080.),
            (-1920., 160.)
        );
        assert_eq!(
            clamp_position(1900., -20., 320., 480., 0., 24., 1920., 1080.),
            (1600., 24.)
        );
    }
}
