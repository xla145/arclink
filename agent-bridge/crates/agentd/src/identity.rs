use crate::{BridgeError, Result};
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
