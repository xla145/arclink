//! One network endpoint per phone identity, shared by pairing and all Macs.
use crate::load_or_create_key;
use bridge_network::PeerNetwork;
use iroh::{endpoint::presets, Endpoint};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
};
use tokio::sync::{Mutex as AsyncMutex, OnceCell};

pub(crate) struct SharedEndpoint {
    key_path: PathBuf,
    endpoint: OnceCell<Endpoint>,
    relays: AsyncMutex<HashMap<String, RelayRegistration>>,
}

impl SharedEndpoint {
    pub(crate) fn for_key(path: &str) -> Arc<Self> {
        static OWNERS: OnceLock<Mutex<HashMap<PathBuf, Weak<SharedEndpoint>>>> = OnceLock::new();
        let path = Path::new(path);
        // Swift passes an absolute application-support path. Canonicalize its
        // parent when possible so equivalent existing directory aliases share.
        let key_path = path
            .parent()
            .and_then(|p| p.canonicalize().ok())
            .and_then(|p| path.file_name().map(|n| p.join(n)))
            .unwrap_or_else(|| {
                if path.is_absolute() {
                    path.to_owned()
                } else {
                    std::env::current_dir().unwrap_or_default().join(path)
                }
            });
        let mut owners = OWNERS
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        owners.retain(|_, owner| owner.strong_count() > 0);
        if let Some(owner) = owners.get(&key_path).and_then(Weak::upgrade) {
            return owner;
        }
        let owner = Arc::new(Self {
            key_path: key_path.clone(),
            endpoint: OnceCell::new(),
            relays: AsyncMutex::new(HashMap::new()),
        });
        owners.insert(key_path, Arc::downgrade(&owner));
        owner
    }

    pub(crate) async fn get(&self) -> Result<Endpoint, (&'static str, String)> {
        self.endpoint
            .get_or_try_init(|| async {
                let secret =
                    load_or_create_key(&self.key_path).map_err(|e| ("identity_error", e))?;
                Endpoint::builder(presets::N0)
                    .dns_resolver(bridge_network::dns_resolver())
                    .secret_key(secret)
                    .alpns(vec![abp_protocol::ALPN.to_vec()])
                    .bind()
                    .await
                    .map_err(|_| {
                        (
                            "network_error",
                            "Could not start the phone endpoint.".into(),
                        )
                    })
            })
            .await
            .cloned()
    }
}

struct RelayRegistration {
    key: Option<String>,
    references: usize,
    previous: Option<Arc<iroh::RelayConfig>>,
}

/// One saved connection or in-flight pairing owns one registration, not the whole endpoint.
pub(crate) struct RelayLease {
    owner: Arc<SharedEndpoint>,
    url: String,
    runtime: tokio::runtime::Handle,
    active: bool,
}
impl RelayLease {
    pub(crate) async fn release(mut self) {
        self.active = false;
        self.owner.release_relay(&self.url).await;
    }
}
impl Drop for RelayLease {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        let owner = self.owner.clone();
        let url = self.url.clone();
        self.runtime.spawn(async move {
            owner.release_relay(&url).await;
        });
    }
}
impl SharedEndpoint {
    pub(crate) async fn register_relay(
        self: &Arc<Self>,
        config: &PeerNetwork,
    ) -> Result<Option<RelayLease>, (&'static str, String)> {
        let Some(relay) = config.relay_config() else {
            return Ok(None);
        };
        let endpoint = self.get().await?;
        let url = relay.url.to_string();
        let mut registrations = self.relays.lock().await;
        if let Some(existing) = registrations.get_mut(&url) {
            if existing.key != config.relay_access_key {
                return Err(("relay_conflict", "This relay already has a different active credential. Update its saved settings explicitly.".into()));
            }
            existing.references += 1;
        } else {
            let previous = endpoint
                .insert_relay(relay.url.clone(), Arc::new(relay))
                .await;
            registrations.insert(
                url.clone(),
                RelayRegistration {
                    key: config.relay_access_key.clone(),
                    references: 1,
                    previous,
                },
            );
        }
        Ok(Some(RelayLease {
            owner: self.clone(),
            url,
            runtime: tokio::runtime::Handle::current(),
            active: true,
        }))
    }
    async fn release_relay(&self, url: &str) {
        let mut registrations = self.relays.lock().await;
        let Some(entry) = registrations.get_mut(url) else {
            return;
        };
        entry.references = entry.references.saturating_sub(1);
        if entry.references != 0 {
            return;
        }
        let previous = registrations.remove(url).and_then(|entry| entry.previous);
        if let Some(endpoint) = self.endpoint.get() {
            if let Ok(url) = url.parse() {
                if let Some(previous) = previous {
                    endpoint.insert_relay(url, previous).await;
                } else {
                    endpoint.remove_relay(&url).await;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn network(key: &str) -> PeerNetwork {
        PeerNetwork::from_json(
            &serde_json::json!({"relay_url":"https://127.0.0.1:9", "relay_access_key":key})
                .to_string(),
        )
        .unwrap()
    }
    #[tokio::test]
    async fn relay_credentials_are_reference_counted_and_conflicts_are_atomic() {
        let dir = tempfile::tempdir().unwrap();
        let owner = SharedEndpoint::for_key(dir.path().join("key").to_str().unwrap());
        let first = owner.register_relay(&network("a")).await.unwrap().unwrap();
        let second = owner.register_relay(&network("a")).await.unwrap().unwrap();
        assert_eq!(
            owner
                .relays
                .lock()
                .await
                .values()
                .next()
                .unwrap()
                .references,
            2
        );
        assert!(matches!(
            owner.register_relay(&network("b")).await,
            Err(("relay_conflict", _))
        ));
        first.release().await;
        assert_eq!(
            owner
                .relays
                .lock()
                .await
                .values()
                .next()
                .unwrap()
                .references,
            1
        );
        second.release().await;
        assert!(owner.relays.lock().await.is_empty());
        let replacement = owner.register_relay(&network("b")).await.unwrap().unwrap();
        replacement.release().await;
        owner.get().await.unwrap().close().await;
    }
    #[tokio::test]
    async fn unrelated_relay_survives_failed_registration_and_removal() {
        let dir = tempfile::tempdir().unwrap();
        let owner = SharedEndpoint::for_key(dir.path().join("key").to_str().unwrap());
        let first = owner.register_relay(&network("a")).await.unwrap().unwrap();
        let mut other = network("b");
        other.hints.relay_url = Some("https://127.0.0.1:10/".into());
        let second = owner.register_relay(&other).await.unwrap().unwrap();
        first.release().await;
        assert_eq!(owner.relays.lock().await.len(), 1);
        assert_eq!(
            owner
                .relays
                .lock()
                .await
                .values()
                .next()
                .unwrap()
                .key
                .as_deref(),
            Some("b")
        );
        second.release().await;
        owner.get().await.unwrap().close().await;
    }
    struct ProgressRecorder(Arc<Mutex<Vec<crate::PairingStage>>>);
    impl crate::PairingProgressCallback for ProgressRecorder {
        fn on_stage(&self, stage: crate::PairingStage) {
            self.0.lock().unwrap().push(stage);
        }
    }

    #[tokio::test]
    async fn pairing_deadline_includes_relay_setup_and_never_claims_approval() {
        use std::time::Duration;
        let directory = tempfile::tempdir().unwrap();
        let path = directory
            .path()
            .join("phone.key")
            .to_string_lossy()
            .to_string();
        let owner = SharedEndpoint::for_key(&path);
        let endpoint = owner.get().await.unwrap();
        let lock = owner.relays.lock().await;
        let stages = Arc::new(Mutex::new(Vec::new()));
        let outcome = tokio::time::timeout(
            Duration::from_secs(2),
            crate::pair_with_deadlines(
                iroh::SecretKey::generate().public().to_string(),
                "s".into(),
                "token".into(),
                "phone".into(),
                path,
                network("key"),
                Some(Box::new(ProgressRecorder(stages.clone()))),
                Duration::from_millis(40),
                Duration::from_secs(1),
            ),
        )
        .await
        .expect("relay setup lock must obey pairing deadline");
        assert!(!outcome.ok);
        assert_eq!(outcome.error_code, "connect_timeout");
        assert_eq!(
            *stages.lock().unwrap(),
            vec![crate::PairingStage::Connecting]
        );
        drop(lock);
        endpoint.close().await;
    }

    #[tokio::test]
    async fn relay_only_pairing_waits_for_approval_and_delivers_success() {
        use abp_protocol::{Frame, Hello, RpcResponse, ALPN, MAX_FRAME_BYTES};
        use iroh::RelayMode;
        use iroh_relay::{
            server::{Access, AccessControl, ClientRequest},
            tls::CaTlsConfig,
        };
        use std::time::Duration;
        #[derive(Debug)]
        struct FixtureAccess;
        impl AccessControl for FixtureAccess {
            async fn on_connect(&self, request: &ClientRequest) -> Access {
                if request.auth_token().as_deref() == Some("pair-test-key") {
                    Access::Allow
                } else {
                    Access::Deny { reason: None }
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(20), async {
            let (_, url, _relay) =
                iroh::test_utils::run_relay_server_with_access(false, Arc::new(FixtureAccess))
                    .await
                    .unwrap();
            let network = PeerNetwork::from_json(
                &serde_json::json!({
                    "relay_url": url.to_string(), "relay_access_key": "pair-test-key"
                })
                .to_string(),
            )
            .unwrap();
            async fn relay_endpoint(network: &PeerNetwork) -> Endpoint {
                Endpoint::builder(presets::Minimal)
                    .alpns(vec![ALPN.to_vec()])
                    .relay_mode(RelayMode::Custom(network.relay_config().unwrap().into()))
                    .clear_ip_transports()
                    .ca_tls_config(CaTlsConfig::insecure_skip_verify())
                    .bind()
                    .await
                    .unwrap()
            }
            let host = relay_endpoint(&network).await;
            let phone = relay_endpoint(&network).await;
            let directory = tempfile::tempdir().unwrap();
            let key_path = directory
                .path()
                .join("phone.key")
                .to_string_lossy()
                .to_string();
            // Inject only the test endpoint; the exported pairing API and framing are real.
            let owner = SharedEndpoint::for_key(&key_path);
            owner.endpoint.set(phone.clone()).unwrap();
            let (pending_tx, pending_rx) = tokio::sync::oneshot::channel();
            let (approve_tx, approve_rx) = tokio::sync::oneshot::channel();
            let listener = host.clone();
            let server = tokio::spawn(async move {
                let conn = listener.accept().await.unwrap().await.unwrap();
                let (mut send, mut recv) = conn.accept_bi().await.unwrap();
                assert!(matches!(
                    abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                        .await
                        .unwrap(),
                    Frame::Hello(_)
                ));
                abp_protocol::write_frame(
                    &mut send,
                    &Frame::Hello(Hello::new(listener.id().to_string())),
                    MAX_FRAME_BYTES,
                )
                .await
                .unwrap();
                assert!(matches!(
                    abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                        .await
                        .unwrap(),
                    Frame::Open(_)
                ));
                abp_protocol::write_frame(
                    &mut send,
                    &Frame::Response(RpcResponse::default()),
                    MAX_FRAME_BYTES,
                )
                .await
                .unwrap();
                let Frame::Pair(request) = abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                    .await
                    .unwrap()
                else {
                    panic!("pair required")
                };
                assert_eq!(request.session_id, "session");
                assert_eq!(request.token, "one-use-token");
                let mut pending_tx = Some(pending_tx);
                let mut approve_rx = Some(approve_rx);
                for state in ["pending", "approved"] {
                    if state == "approved" {
                        approve_rx.take().unwrap().await.unwrap();
                    }
                    abp_protocol::write_frame(
                        &mut send,
                        &Frame::Response(RpcResponse {
                            rpc_id: "pair".into(),
                            body_json: serde_json::json!({"state": state}).to_string(),
                            ..Default::default()
                        }),
                        MAX_FRAME_BYTES,
                    )
                    .await
                    .unwrap();
                    if state == "pending" {
                        pending_tx.take().unwrap().send(()).unwrap();
                    }
                }
                send.finish().unwrap();
                let _ = send.stopped().await;
                assert_eq!(bridge_network::selected_path(&conn), "relay");
            });
            let config = crate::PeerNetworkConfig {
                relay_url: network.hints.relay_url,
                relay_access_key: network.relay_access_key,
                direct_addresses: vec![],
            };
            let stages = Arc::new(Mutex::new(Vec::new()));
            let pairing = tokio::spawn(crate::pair_over_iroh_with_progress(
                host.id().to_string(),
                "session".into(),
                "one-use-token".into(),
                "phone".into(),
                key_path,
                config,
                Box::new(ProgressRecorder(stages.clone())),
            ));
            pending_rx.await.unwrap();
            assert!(
                !pairing.is_finished(),
                "submission must not count as approval"
            );
            approve_tx.send(()).unwrap();
            let outcome = pairing.await.unwrap();
            assert!(outcome.ok, "{}", outcome.error_code);
            assert!(!outcome.pending);
            assert_eq!(outcome.device_id, phone.id().to_string());
            assert_eq!(
                *stages.lock().unwrap(),
                vec![
                    crate::PairingStage::Connecting,
                    crate::PairingStage::Handshaking,
                    crate::PairingStage::AwaitingApproval
                ]
            );
            server.await.unwrap();
            phone.close().await;
            host.close().await;
        })
        .await
        .expect("relay pairing deadline");
    }
}
