//! iOS-side ABP client. Pairing rides the same iroh endpoint as the daemon,
//! so it works across the internet, not only on the LAN.
mod connection;
mod endpoint;
pub use connection::{
    AgentInfo, AgentIoCallback, BridgeConnection, BridgeError, ConnectionState, IoHandle, MacMessage,
    MacProject, ProcessInfo, SystemInfo,
};

use iroh::{endpoint::Connection, EndpointId, SecretKey};
use std::{path::Path, str::FromStr, time::Duration};
use tokio::io::AsyncReadExt;

uniffi::setup_scaffolding!("agent_bridge_client");

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(40);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(130);
pub(crate) const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
pub(crate) const WRITE_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(uniffi::Record)]
pub struct PairOutcome {
    pub ok: bool,
    /// This phone's stable iroh node id (the device id the Mac binds to).
    pub device_id: String,
    /// Pending = Mac is showing the approval prompt.
    pub pending: bool,
    pub error_code: String,
    pub error_message: String,
}

fn fail(device_id: String, code: &str, message: &str) -> PairOutcome {
    PairOutcome {
        ok: false,
        device_id,
        pending: false,
        error_code: code.into(),
        error_message: message.into(),
    }
}

pub(crate) fn load_or_create_key(path: &Path) -> Result<SecretKey, String> {
    // Serialize initialization even when callers bypass the shared owner.
    static KEY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = KEY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let bytes =
                hex::decode(text.trim()).map_err(|_| "Invalid phone identity file.".to_string())?;
            let bytes: [u8; 32] = bytes
                .try_into()
                .map_err(|_| "Invalid phone identity file.".to_string())?;
            return Ok(SecretKey::from_bytes(&bytes));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("Could not read phone identity file.".into()),
    }
    let key = SecretKey::generate();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|_| "Could not create identity directory.".to_string())?;
    }
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|_| "Could not create phone identity file.".to_string())?;
    file.write_all(hex::encode(key.to_bytes()).as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|_| "Could not save phone identity file.".to_string())?;
    Ok(key)
}

pub(crate) async fn read_frame(
    recv: &mut iroh::endpoint::RecvStream,
    max: usize,
) -> Result<abp_protocol::Frame, String> {
    let len = recv
        .read_u32()
        .await
        .map_err(|_| "stream closed".to_string())? as usize;
    if len == 0 || len > max {
        return Err("invalid frame length".into());
    }
    let mut bytes = vec![0u8; len];
    recv.read_exact(&mut bytes)
        .await
        .map_err(|_| "incomplete frame".to_string())?;
    abp_protocol::Frame::decode_payload(&bytes).map_err(|e| e.to_string())
}

pub(crate) async fn write_frame(
    send: &mut iroh::endpoint::SendStream,
    frame: &abp_protocol::Frame,
    max: usize,
) -> Result<(), String> {
    let bytes = frame.encode(max).map_err(|e| e.to_string())?;
    tokio::time::timeout(WRITE_TIMEOUT, send.write_all(&bytes))
        .await
        .map_err(|_| "send timed out".to_string())?
        .map_err(|_| "could not send frame".to_string())?;
    Ok(())
}

/// Connect to the Mac's iroh endpoint and complete pairing. The phone keeps
/// one secret key file so the Mac's grant survives re-pairing attempts.
#[uniffi::export(async_runtime = "tokio")]
pub async fn pair_over_iroh(
    endpoint_id: String,
    session_id: String,
    token: String,
    device_name: String,
    key_path: String,
) -> PairOutcome {
    pair_inner(endpoint_id, session_id, token, device_name, key_path).await
}

async fn pair_inner(
    endpoint_id: String,
    session_id: String,
    token: String,
    device_name: String,
    key_path: String,
) -> PairOutcome {
    let owner = endpoint::SharedEndpoint::for_key(&key_path);
    let endpoint = match owner.get().await {
        Ok(endpoint) => endpoint,
        Err((code, error)) => return fail(String::new(), code, &error),
    };
    let device_id = endpoint.id().to_string();
    let node = match EndpointId::from_str(&endpoint_id) {
        Ok(node) => node,
        Err(_) => {
            return fail(
                device_id,
                "invalid_params",
                "The QR code has an invalid endpoint id.",
            )
        }
    };
    let connect = tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect(node, abp_protocol::ALPN));
    let connection: Connection = match connect.await {
        Ok(Ok(connection)) => connection,
        Ok(Err(_)) => {
            return fail(
                device_id,
                "unreachable",
                "Could not reach the Mac. Check both networks.",
            )
        }
        Err(_) => {
            return fail(
                device_id,
                "timeout",
                "Connecting to the Mac timed out. Direct and relay paths both failed.",
            )
        }
    };
    let (mut send, mut recv) = match connection.open_bi().await {
        Ok(pair) => pair,
        Err(_) => {
            return fail(
                device_id,
                "network_error",
                "Could not open a pairing stream.",
            )
        }
    };
    let hello = abp_protocol::Frame::Hello(abp_protocol::Hello::new(device_id.clone()));
    if let Err(error) = write_frame(&mut send, &hello, abp_protocol::MAX_FRAME_BYTES).await {
        return fail(device_id, "network_error", &error);
    }
    let peer_hello = match tokio::time::timeout(
        HELLO_TIMEOUT,
        read_frame(&mut recv, abp_protocol::MAX_FRAME_BYTES),
    )
    .await
    {
        Ok(Ok(abp_protocol::Frame::Hello(value))) => value,
        Ok(Ok(_)) => {
            return fail(
                device_id,
                "protocol_error",
                "The Mac did not answer with Hello.",
            )
        }
        Ok(Err(error)) => return fail(device_id, "protocol_error", &error),
        Err(_) => {
            return fail(
                device_id,
                "timeout",
                "The Mac did not complete the handshake.",
            )
        }
    };
    let max = match peer_hello.negotiate() {
        Ok(max) => max,
        Err(_) => {
            return fail(
                device_id,
                "incompatible",
                "The Mac speaks an incompatible protocol.",
            )
        }
    };
    let open = abp_protocol::Frame::Open(abp_protocol::StreamOpen {
        kind: abp_protocol::STREAM_PAIR,
        ..Default::default()
    });
    if let Err(error) = write_frame(&mut send, &open, max).await {
        return fail(device_id, "network_error", &error);
    }
    // Pair-stream ack, then submit the scanned invitation.
    match tokio::time::timeout(HELLO_TIMEOUT, read_frame(&mut recv, max)).await {
        Ok(Ok(abp_protocol::Frame::Response(_))) => {}
        Ok(Ok(abp_protocol::Frame::Error(error))) => {
            return fail(device_id, &error.code, &error.message)
        }
        _ => {
            return fail(
                device_id,
                "protocol_error",
                "Unexpected reply on the pair stream.",
            )
        }
    }
    let request = abp_protocol::Frame::Pair(abp_protocol::PairRequest {
        session_id,
        token,
        name: device_name,
    });
    if let Err(error) = write_frame(&mut send, &request, max).await {
        return fail(device_id, "network_error", &error);
    }
    // First response: the Mac accepted the token and shows the approval prompt.
    match tokio::time::timeout(APPROVAL_TIMEOUT, read_frame(&mut recv, max)).await {
        Ok(Ok(abp_protocol::Frame::Response(value))) => {
            if !value.error_code.is_empty() {
                return fail(device_id, &value.error_code, &value.error_message);
            }
        }
        Ok(Ok(abp_protocol::Frame::Error(error))) => {
            return fail(device_id, &error.code, &error.message)
        }
        Ok(Ok(_)) => {
            return fail(
                device_id,
                "protocol_error",
                "Unexpected reply on the pair stream.",
            )
        }
        Ok(Err(error)) => return fail(device_id, "protocol_error", &error),
        Err(_) => {
            return fail(
                device_id,
                "timeout",
                "The Mac did not acknowledge the invitation.",
            )
        }
    }
    // Second response arrives once the user approves on the Mac.
    loop {
        match tokio::time::timeout(APPROVAL_TIMEOUT, read_frame(&mut recv, max)).await {
            Ok(Ok(abp_protocol::Frame::Response(value))) => {
                if !value.error_code.is_empty() {
                    return fail(device_id, &value.error_code, &value.error_message);
                }
                let state = serde_json::from_str::<serde_json::Value>(&value.body_json)
                    .ok()
                    .and_then(|body| {
                        body.get("state")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_string)
                    })
                    .unwrap_or_default();
                match state.as_str() {
                    "approved" => {
                        return PairOutcome {
                            ok: true,
                            device_id,
                            pending: false,
                            error_code: String::new(),
                            error_message: String::new(),
                        }
                    }
                    "pending" => continue,
                    other => {
                        return fail(
                            device_id,
                            "pairing_state",
                            &format!("Pairing ended as {other}."),
                        )
                    }
                }
            }
            Ok(Ok(abp_protocol::Frame::Error(error))) => {
                return fail(device_id, &error.code, &error.message)
            }
            Ok(Ok(_)) => {
                return fail(
                    device_id,
                    "protocol_error",
                    "Unexpected reply while waiting.",
                )
            }
            Ok(Err(error)) => return fail(device_id, "protocol_error", &error),
            Err(_) => {
                return fail(
                    device_id,
                    "timeout",
                    "Timed out waiting for approval on the Mac.",
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn concurrent_identity_creation_keeps_one_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || super::load_or_create_key(&path).unwrap().to_bytes())
            })
            .collect();
        let keys: Vec<_> = threads.into_iter().map(|t| t.join().unwrap()).collect();
        assert!(keys.iter().all(|k| k == &keys[0]));
    }

    #[test]
    fn corrupt_identity_is_not_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        std::fs::write(&path, "broken").unwrap();
        assert!(super::load_or_create_key(&path).is_err());
        assert_eq!(std::fs::read_to_string(path).unwrap(), "broken");
    }

    #[test]
    fn key_file_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        let first = super::load_or_create_key(&path).unwrap();
        let second = super::load_or_create_key(&path).unwrap();
        assert_eq!(first.to_bytes(), second.to_bytes());
    }
}
