use agentd::{BridgeError, Result};
use serde::{Deserialize, Serialize};
use std::{
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::{AppHandle, Manager};

#[derive(Clone, Serialize)]
pub struct Status {
    enabled: bool,
    active: bool,
    supported: bool,
    error: Option<BridgeError>,
}
#[derive(Default)]
pub struct KeepAwake(pub Mutex<Controller>);
#[derive(Default)]
pub struct Controller {
    path: Option<PathBuf>,
    enabled: bool,
    assertion: Option<Assertion>,
    error: Option<BridgeError>,
    stopped: bool,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Preference {
    version: u8,
    enabled: bool,
}
fn failure(message: &str) -> BridgeError {
    BridgeError::new("keep_awake_error", message)
}
fn save(path: &Path, enabled: bool) -> Result<()> {
    let mut file = tempfile::NamedTempFile::new_in(
        path.parent().ok_or_else(|| failure("无法定位偏好目录。"))?,
    )
    .map_err(|_| failure("无法保存保持活跃设置，请检查应用数据目录。"))?;
    let bytes = serde_json::to_vec(&Preference {
        version: 1,
        enabled,
    })
    .map_err(|_| failure("无法保存偏好。"))?;
    file.write_all(&bytes)
        .and_then(|_| file.as_file().sync_all())
        .map_err(|_| failure("无法写入保持活跃设置。"))?;
    file.persist(path)
        .map_err(|_| failure("无法保存保持活跃设置。"))?;
    Ok(())
}
impl Controller {
    fn status(&self) -> Status {
        Status {
            enabled: self.enabled,
            active: self.assertion.is_some(),
            supported: cfg!(target_os = "macos"),
            error: self.error.clone(),
        }
    }
    fn restore(&mut self, path: PathBuf) -> Result<()> {
        let preference = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Preference>(&bytes).map_err(|_| {
                failure("保持活跃偏好损坏，请检查应用数据目录中的 keep-awake-v1.json。")
            })?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Preference {
                version: 1,
                enabled: false,
            },
            Err(_) => return Err(failure("无法读取保持活跃设置，请检查应用数据目录。")),
        };
        if preference.version != 1 {
            return Err(failure("保持活跃设置版本不受支持。"));
        }
        self.path = Some(path);
        self.enabled = preference.enabled;
        if self.enabled {
            self.assertion = Some(Assertion::acquire()?);
        }
        Ok(())
    }
    fn set(&mut self, enabled: bool) -> Result<Status> {
        if self.stopped {
            return Err(failure("应用正在退出或更新，请稍候。"));
        }
        let path = self.path.as_ref().ok_or_else(|| {
            self.error
                .clone()
                .unwrap_or_else(|| failure("保持活跃偏好尚不可用，请重启应用后重试。"))
        })?;
        if !cfg!(target_os = "macos") {
            return Err(failure("当前系统暂不支持保持活跃。"));
        }
        // Stage a new assertion before persisting. A failed write drops only this new owner.
        let staged = if enabled && self.assertion.is_none() {
            Some(Assertion::acquire()?)
        } else {
            None
        };
        save(path, enabled)?;
        if enabled {
            if staged.is_some() {
                self.assertion = staged;
            }
        } else if let Some(assertion) = self.assertion.as_mut() {
            if let Err(error) = assertion.release() {
                // Restore saved intent if native release fails; retain the live owner.
                let _ = save(path, self.enabled);
                return Err(error);
            }
            self.assertion = None;
        }
        self.enabled = enabled;
        self.error = None;
        Ok(self.status())
    }
    pub fn stop(&mut self) -> Result<()> {
        self.stopped = true;
        if let Some(assertion) = self.assertion.as_mut() {
            assertion.release()?;
        }
        self.assertion = None;
        Ok(())
    }
}
pub fn initialize(app: &AppHandle) {
    let state = app.state::<KeepAwake>();
    let mut controller = state.0.lock().unwrap();
    let result = app
        .path()
        .app_data_dir()
        .map_err(|_| failure("无法定位应用数据目录。"))
        .and_then(|directory| {
            std::fs::create_dir_all(&directory).map_err(|_| failure("无法创建偏好目录。"))?;
            controller.restore(directory.join("keep-awake-v1.json"))
        });
    if let Err(error) = result {
        controller.error = Some(error);
    }
}
#[tauri::command]
pub fn get_keep_awake(app: AppHandle) -> Status {
    app.state::<KeepAwake>().0.lock().unwrap().status()
}
#[tauri::command]
pub fn set_keep_awake(app: AppHandle, enabled: bool) -> Result<Status> {
    let state = app.state::<KeepAwake>();
    let mut controller = state.0.lock().unwrap();
    let result = controller.set(enabled);
    if let Err(error) = &result {
        controller.error = Some(error.clone());
    }
    result
}

struct Assertion {
    id: Option<u32>,
}
impl Assertion {
    fn acquire() -> Result<Self> {
        #[cfg(target_os = "macos")]
        unsafe {
            let kind = CFStringCreateWithCString(
                std::ptr::null(),
                c"PreventUserIdleSystemSleep".as_ptr(),
                0x08000100,
            );
            let name = CFStringCreateWithCString(
                std::ptr::null(),
                c"ArcLink remote Agent availability".as_ptr(),
                0x08000100,
            );
            if kind.is_null() || name.is_null() {
                if !kind.is_null() {
                    CFRelease(kind);
                }
                if !name.is_null() {
                    CFRelease(name);
                }
                return Err(failure("无法创建系统保持活跃请求。"));
            }
            let mut id = 0;
            let result = IOPMAssertionCreateWithName(kind, 255, name, &mut id);
            CFRelease(kind);
            CFRelease(name);
            if result != 0 {
                return Err(failure("系统未能开启保持活跃，请重试。"));
            }
            Ok(Self { id: Some(id) })
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(failure("当前系统暂不支持保持活跃。"))
        }
    }
    fn release(&mut self) -> Result<()> {
        #[cfg(target_os = "macos")]
        if let Some(id) = self.id {
            if unsafe { IOPMAssertionRelease(id) } != 0 {
                return Err(failure("系统未能关闭保持活跃，请重试。"));
            }
        }
        self.id = None;
        Ok(())
    }
}
impl Drop for Assertion {
    fn drop(&mut self) {
        let _ = self.release();
    }
}
#[cfg(target_os = "macos")]
#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPMAssertionCreateWithName(
        kind: *const std::ffi::c_void,
        level: u32,
        name: *const std::ffi::c_void,
        id: *mut u32,
    ) -> i32;
    fn IOPMAssertionRelease(id: u32) -> i32;
}
#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFStringCreateWithCString(
        allocator: *const std::ffi::c_void,
        text: *const std::ffi::c_char,
        encoding: u32,
    ) -> *const std::ffi::c_void;
    fn CFRelease(value: *const std::ffi::c_void);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "macos")]
    fn owns_native_assertion() -> bool {
        let output = std::process::Command::new("/usr/bin/pmset")
            .args(["-g", "assertions"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let owner = format!("pid {}(", std::process::id());
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.contains(&owner) && line.contains("ArcLink remote Agent availability"))
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_assertion_restores_preference_and_releases_without_touching_user_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pref.json");
        save(&path, true).unwrap();
        let mut controller = Controller::default();
        controller.restore(path.clone()).unwrap();
        assert!(controller.status().active);
        assert!(owns_native_assertion());
        let original_id = controller.assertion.as_ref().unwrap().id;
        controller.set(true).unwrap();
        assert_eq!(controller.assertion.as_ref().unwrap().id, original_id);
        controller.set(false).unwrap();
        assert!(!controller.status().active);
        controller.set(true).unwrap();
        controller.stop().unwrap();
        assert!(!controller.status().active);
        assert!(!owns_native_assertion());
        // An unwritable destination must release the newly staged assertion.
        let mut failed = Controller {
            path: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        assert!(failed.set(true).is_err());
        assert!(!failed.status().active);
        assert!(!failed.status().enabled);
        assert!(!owns_native_assertion());
        assert!(
            serde_json::from_slice::<Preference>(&std::fs::read(path).unwrap())
                .unwrap()
                .enabled
        );
    }
    #[test]
    fn missing_defaults_off_and_corrupt_preferences_are_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pref.json");
        let mut controller = Controller::default();
        controller.restore(path.clone()).unwrap();
        assert!(!controller.status().enabled);
        assert!(!path.exists());
        std::fs::write(&path, b"broken").unwrap();
        assert!(Controller::default().restore(path.clone()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"broken");
    }
    #[test]
    fn persistence_and_stop_prevent_new_mutations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pref.json");
        save(&path, false).unwrap();
        let mut controller = Controller::default();
        controller.restore(path).unwrap();
        controller.stop().unwrap();
        assert!(controller.set(true).is_err());
    }
}
