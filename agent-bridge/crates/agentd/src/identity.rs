use crate::{BridgeError, Result};

/// Explicit development storage; never compiled into a release build or used
/// as a fallback when Keychain access fails.
#[cfg(all(debug_assertions, unix))]
pub fn load_or_create_development(directory: &std::path::Path) -> Result<[u8; 32]> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let error = || BridgeError::new("identity_error", "Could not access development identity.");
    std::fs::create_dir_all(directory).map_err(|_| error())?;
    let path = directory.join("development-identity-v1.key");
    match std::fs::read(&path) {
        Ok(bytes) => {
            let key = bytes.try_into().map_err(|_| {
                BridgeError::new(
                    "identity_error",
                    "Development identity has an invalid length.",
                )
            })?;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| error())?;
            Ok(key)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let key: [u8; 32] = rand::random();
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&path)
                .map_err(|_| error())?;
            file.write_all(&key).map_err(|_| error())?;
            file.sync_all().map_err(|_| error())?;
            Ok(key)
        }
        Err(_) => Err(error()),
    }
}

/// The network identity never falls back to a plaintext file.
pub fn load_or_create() -> Result<[u8; 32]> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::{get_generic_password, set_generic_password};
        const SERVICE: &str = "dev.agent-bridge.desktop.identity";
        const ACCOUNT: &str = "iroh-ed25519-v1";
        match get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => bytes.try_into().map_err(|_| {
                BridgeError::new("identity_error", "Stored identity has an invalid length.")
            }),
            Err(error) if error.code() == -25300 => {
                let key: [u8; 32] = rand::random();
                set_generic_password(SERVICE, ACCOUNT, &key).map_err(|_| {
                    BridgeError::new(
                        "identity_error",
                        "Could not save network identity in Keychain.",
                    )
                })?;
                Ok(key)
            }
            Err(_) => Err(BridgeError::new(
                "identity_error",
                "Keychain access failed. Unlock your keychain and retry.",
            )),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(BridgeError::new(
            "unsupported",
            "Secure identity storage is not yet validated on this platform.",
        ))
    }
}

#[cfg(all(test, debug_assertions, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn development_identity_survives_restart_and_is_private() {
        let directory = tempfile::tempdir().unwrap();
        let first = load_or_create_development(directory.path()).unwrap();
        assert_eq!(first, load_or_create_development(directory.path()).unwrap());
        let path = directory.path().join("development-identity-v1.key");
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn corrupt_development_identity_is_not_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("development-identity-v1.key");
        std::fs::write(&path, b"invalid").unwrap();
        assert!(load_or_create_development(directory.path()).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"invalid");
    }
}
