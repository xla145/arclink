//! macOS debug and release share the existing Keychain relay configuration.
use agentd::{BridgeError, Result};
use bridge_network::{AddressHints, PeerNetwork, DEFAULT_PRIVATE_RELAY};
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
pub struct StoredNetwork {
    pub enabled: bool,
    pub relay_url: String,
    pub access_key: Option<String>,
}
impl Default for StoredNetwork {
    fn default() -> Self {
        Self {
            enabled: false,
            relay_url: DEFAULT_PRIVATE_RELAY.into(),
            access_key: None,
        }
    }
}
#[derive(Serialize)]
pub struct NetworkSettings {
    pub enabled: bool,
    pub relay_url: String,
    pub has_access_key: bool,
}
#[derive(Deserialize)]
pub struct NetworkUpdate {
    pub enabled: bool,
    pub relay_url: String,
    /// null keeps the stored key; empty explicitly clears it.
    pub access_key: Option<String>,
}
impl StoredNetwork {
    pub fn descriptor(&self) -> NetworkSettings {
        NetworkSettings {
            enabled: self.enabled,
            relay_url: self.relay_url.clone(),
            has_access_key: self.access_key.is_some(),
        }
    }
    pub fn network(&self) -> Result<PeerNetwork> {
        if !self.enabled {
            return Ok(PeerNetwork::default());
        }
        PeerNetwork {
            hints: AddressHints {
                relay_url: Some(self.relay_url.clone()),
                direct_addresses: vec![],
            },
            relay_access_key: self.access_key.clone(),
        }
        .validate()
        .map_err(|_| invalid())
    }
    pub fn updated(&self, update: NetworkUpdate) -> Result<Self> {
        let relay_url =
            bridge_network::canonical_relay_url(&update.relay_url).map_err(|_| invalid())?;
        let access_key = match update.access_key {
            None => self.access_key.clone(),
            Some(key) if key.is_empty() => None,
            Some(key) => Some(key),
        };
        let next = Self {
            enabled: update.enabled,
            relay_url,
            access_key,
        };
        // Validate credentials even while disabled so broken settings cannot be saved.
        PeerNetwork {
            hints: AddressHints {
                relay_url: Some(next.relay_url.clone()),
                direct_addresses: vec![],
            },
            relay_access_key: next.access_key.clone(),
        }
        .validate()
        .map_err(|_| invalid())?;
        Ok(next)
    }
}
fn invalid() -> BridgeError {
    BridgeError::new("invalid_network", "请输入有效的 HTTPS 中继地址与访问密钥。")
}
fn storage_error() -> BridgeError {
    BridgeError::new(
        "credential_error",
        if cfg!(all(debug_assertions, not(target_os = "macos"))) {
            "无法访问开发中继配置，请检查应用数据目录。"
        } else {
            "无法访问系统中继凭据，请解锁钥匙串后重试。"
        },
    )
}
#[cfg(target_os = "macos")]
const SERVICE: &str = "dev.agent-bridge.desktop.relay";
#[cfg(target_os = "macos")]
const ACCOUNT: &str = "private-relay-v1";
pub fn load(_app: &tauri::AppHandle) -> Result<StoredNetwork> {
    #[cfg(all(debug_assertions, not(target_os = "macos")))]
    {
        load_development(&development_path(_app)?)
    }
    #[cfg(target_os = "macos")]
    {
        match security_framework::passwords::get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => {
                let settings: StoredNetwork =
                    serde_json::from_slice(&bytes).map_err(|_| storage_error())?;
                settings.network()?;
                Ok(settings)
            }
            Err(error) if error.code() == -25300 => Ok(StoredNetwork::default()),
            Err(_) => Err(storage_error()),
        }
    }
    #[cfg(all(not(debug_assertions), not(target_os = "macos")))]
    {
        Err(storage_error())
    }
}
pub fn save(_app: &tauri::AppHandle, settings: &StoredNetwork) -> Result<()> {
    #[cfg(all(debug_assertions, not(target_os = "macos")))]
    {
        save_development(&development_path(_app)?, settings)
    }
    #[cfg(target_os = "macos")]
    {
        let bytes = serde_json::to_vec(settings).map_err(|_| storage_error())?;
        security_framework::passwords::set_generic_password(SERVICE, ACCOUNT, &bytes)
            .map_err(|_| storage_error())
    }
    #[cfg(all(not(debug_assertions), not(target_os = "macos")))]
    {
        let _ = settings;
        Err(storage_error())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn update_is_write_only_and_preserves_or_clears_key() {
        let old = StoredNetwork {
            access_key: Some("fixture-key".into()),
            ..Default::default()
        };
        let update = |key| NetworkUpdate {
            enabled: true,
            relay_url: DEFAULT_PRIVATE_RELAY.into(),
            access_key: key,
        };
        let next = old.updated(update(None)).unwrap();
        assert_eq!(next.access_key.as_deref(), Some("fixture-key"));
        assert!(!serde_json::to_string(&next.descriptor())
            .unwrap()
            .contains("fixture-key"));
        assert!(old
            .updated(update(Some(String::new())))
            .unwrap()
            .access_key
            .is_none());
        assert!(old.updated(update(Some("bad\nkey".into()))).is_err());
        assert_eq!(old.access_key.as_deref(), Some("fixture-key"));
    }
}

#[cfg(all(debug_assertions, not(target_os = "macos")))]
fn development_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf> {
    use tauri::Manager;
    let directory = app.path().app_data_dir().map_err(|_| storage_error())?;
    std::fs::create_dir_all(&directory).map_err(|_| storage_error())?;
    Ok(directory.join("development-relay-v1.json"))
}

#[cfg(all(debug_assertions, any(not(target_os = "macos"), test)))]
fn load_development(path: &std::path::Path) -> Result<StoredNetwork> {
    match std::fs::read(path) {
        Ok(bytes) => {
            let settings: StoredNetwork =
                serde_json::from_slice(&bytes).map_err(|_| storage_error())?;
            settings.network()?;
            Ok(settings)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(StoredNetwork::default()),
        Err(_) => Err(storage_error()),
    }
}

#[cfg(all(debug_assertions, any(not(target_os = "macos"), test)))]
fn save_development(path: &std::path::Path, settings: &StoredNetwork) -> Result<()> {
    use std::io::Write;
    let bytes = serde_json::to_vec(settings).map_err(|_| storage_error())?;
    let mut file = tempfile::NamedTempFile::new_in(path.parent().ok_or_else(storage_error)?)
        .map_err(|_| storage_error())?;
    file.write_all(&bytes).map_err(|_| storage_error())?;
    file.as_file().sync_all().map_err(|_| storage_error())?;
    file.persist(path).map_err(|_| storage_error())?;
    Ok(())
}

#[cfg(all(test, debug_assertions, unix))]
mod development_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn relay_settings_persist_privately_and_preserve_corrupt_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("relay.json");
        assert!(!load_development(&path).unwrap().enabled);
        let settings = StoredNetwork {
            enabled: true,
            access_key: Some("fixture-key".into()),
            ..Default::default()
        };
        save_development(&path, &settings).unwrap();
        assert_eq!(
            load_development(&path).unwrap().access_key,
            settings.access_key
        );
        save_development(&path, &StoredNetwork::default()).unwrap();
        assert!(load_development(&path).unwrap().access_key.is_none());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::write(&path, b"invalid").unwrap();
        assert!(load_development(&path).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"invalid");
    }
}
