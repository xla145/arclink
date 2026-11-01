//! Local, authenticated HTTPS relay; no public network or deployed credentials.
use abp_protocol::{Frame, RpcRequest, RpcResponse, ALPN, MAX_FRAME_BYTES};
use bridge_network::{selected_path, AddressHints, PeerNetwork};
use iroh::Watcher;
use iroh::{endpoint::presets, Endpoint, RelayMode};
use iroh_relay::{
    server::{Access, AccessControl, ClientRequest},
    tls::CaTlsConfig,
};
use std::{sync::Arc, time::Duration};

#[derive(Debug)]
struct TokenAccess;
impl AccessControl for TokenAccess {
    async fn on_connect(&self, request: &ClientRequest) -> Access {
        if request.auth_token().as_deref() == Some("fixture-key") {
            Access::Allow
        } else {
            Access::Deny {
                reason: Some("invalid fixture credential".into()),
            }
        }
    }
}
async fn endpoint(config: &PeerNetwork, relay_only: bool) -> Endpoint {
    let mut builder = Endpoint::builder(presets::Minimal)
        .alpns(vec![ALPN.to_vec()])
        .relay_mode(RelayMode::Custom(config.relay_config().unwrap().into()))
        .ca_tls_config(CaTlsConfig::insecure_skip_verify());
    if relay_only {
        builder = builder.clear_ip_transports();
    }
    builder.bind().await.unwrap()
}
async fn round_trip(a: &Endpoint, b: &Endpoint, config: &PeerNetwork) -> String {
    let mut hints = config.clone();
    hints.hints.direct_addresses = b.addr().ip_addrs().map(ToString::to_string).collect();
    let addr = hints.peer_addr(&b.id().to_string()).unwrap();
    tokio::time::timeout(Duration::from_secs(12), async {
        let server = async {
            let connection = b.accept().await.unwrap().await.unwrap();
            let (mut send, mut recv) = connection.accept_bi().await.unwrap();
            let Frame::Request(request) = abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                .await
                .unwrap()
            else {
                panic!("RPC")
            };
            assert_eq!(request.method, "Ping");
            abp_protocol::write_frame(
                &mut send,
                &Frame::Response(RpcResponse {
                    rpc_id: request.rpc_id,
                    body_json: "null".into(),
                    ..Default::default()
                }),
                MAX_FRAME_BYTES,
            )
            .await
            .unwrap();
            send.finish().unwrap();
            // Keep the QUIC connection alive until receipt is acknowledged.
            let _ = send.stopped().await;
        };
        let client = async {
            let connection = a.connect(addr, ALPN).await.unwrap();
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            abp_protocol::write_frame(
                &mut send,
                &Frame::Request(RpcRequest {
                    rpc_id: "fixture".into(),
                    method: "Ping".into(),
                    body_json: "null".into(),
                    timeout_ms: 5000,
                }),
                MAX_FRAME_BYTES,
            )
            .await
            .unwrap();
            let Frame::Response(response) = abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                .await
                .unwrap()
            else {
                panic!("response")
            };
            assert_eq!(response.rpc_id, "fixture");
            selected_path(&connection).to_string()
        };
        let (_, path) = tokio::join!(server, client);
        path
    })
    .await
    .unwrap()
}
#[tokio::test]
async fn authenticated_forced_relay_and_wrong_key_denial() {
    let (_, url, _server) =
        iroh::test_utils::run_relay_server_with_access(false, Arc::new(TokenAccess))
            .await
            .unwrap();
    let network = PeerNetwork {
        hints: AddressHints {
            relay_url: Some(url.to_string()),
            direct_addresses: vec![],
        },
        relay_access_key: Some("fixture-key".into()),
    }
    .validate()
    .unwrap();
    let a = endpoint(&network, true).await;
    let b = endpoint(&network, true).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(a.online(), b.online());
    })
    .await
    .unwrap();
    assert_eq!(round_trip(&a, &b, &network).await, "relay");
    let mut wrong = network.clone();
    wrong.relay_access_key = Some("incorrect".into());
    let denied = endpoint(&wrong, true).await;
    assert!(
        tokio::time::timeout(Duration::from_secs(2), denied.online())
            .await
            .is_err()
    );
    assert!(denied
        .home_relay_status()
        .get()
        .iter()
        .any(|status| status.auth_denied_reason() == Some("invalid fixture credential")));
    denied.close().await;
    a.close().await;
    b.close().await;
}
#[tokio::test]
async fn unavailable_private_relay_keeps_direct_rpc_working() {
    let network = PeerNetwork::from_json(
        r#"{"relay_url":"https://127.0.0.1:9","relay_access_key":"fixture-key"}"#,
    )
    .unwrap();
    let a = endpoint(&network, false).await;
    let b = endpoint(&network, false).await;
    assert_eq!(round_trip(&a, &b, &network).await, "direct");
    a.close().await;
    b.close().await;
}

#[tokio::test]
async fn usable_private_relay_and_direct_candidates_select_direct() {
    let (_, url, _server) =
        iroh::test_utils::run_relay_server_with_access(false, Arc::new(TokenAccess))
            .await
            .unwrap();
    let network = PeerNetwork {
        hints: AddressHints {
            relay_url: Some(url.to_string()),
            direct_addresses: vec![],
        },
        relay_access_key: Some("fixture-key".into()),
    }
    .validate()
    .unwrap();
    let a = endpoint(&network, false).await;
    let b = endpoint(&network, false).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        tokio::join!(a.online(), b.online());
    })
    .await
    .unwrap();
    assert_eq!(round_trip(&a, &b, &network).await, "direct");
    a.close().await;
    b.close().await;
}

/// Only the relay address is known at dial time. iroh discovers direct addresses
/// over that connection; the original bidirectional stream must survive migration.
#[tokio::test]
async fn relay_only_invitation_upgrades_original_stream_to_direct() {
    let (_, url, _server) =
        iroh::test_utils::run_relay_server_with_access(false, Arc::new(TokenAccess))
            .await
            .unwrap();
    let network = PeerNetwork {
        hints: AddressHints {
            relay_url: Some(url.to_string()),
            direct_addresses: vec![],
        },
        relay_access_key: Some("fixture-key".into()),
    }
    .validate()
    .unwrap();
    let a = endpoint(&network, false).await;
    let b = endpoint(&network, false).await;
    tokio::time::timeout(Duration::from_secs(15), async {
        tokio::join!(a.online(), b.online());
        let addr = network.peer_addr(&b.id().to_string()).unwrap();
        let client = async {
            let connection = a.connect(addr, ALPN).await.unwrap();
            assert_eq!(
                selected_path(&connection),
                "relay",
                "initial relay-only dial must be relayed"
            );
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            assert_eq!(
                selected_path(&connection),
                "relay",
                "original stream must exist while relay is selected"
            );
            for sequence in 0..2 {
                if sequence == 1 {
                    while selected_path(&connection) != "direct" {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                }
                let id = sequence.to_string();
                abp_protocol::write_frame(
                    &mut send,
                    &Frame::Request(RpcRequest {
                        rpc_id: id.clone(),
                        method: "Ping".into(),
                        body_json: "null".into(),
                        timeout_ms: 5000,
                    }),
                    MAX_FRAME_BYTES,
                )
                .await
                .unwrap();
                let Frame::Response(response) =
                    abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                        .await
                        .unwrap()
                else {
                    panic!("response")
                };
                assert_eq!(response.rpc_id, id);
            }
            assert_eq!(selected_path(&connection), "direct");
            send.finish().unwrap();
        };
        let server = async {
            let connection = b.accept().await.unwrap().await.unwrap();
            let (mut send, mut recv) = connection.accept_bi().await.unwrap();
            for sequence in 0..2 {
                let Frame::Request(request) = abp_protocol::read_frame(&mut recv, MAX_FRAME_BYTES)
                    .await
                    .unwrap()
                else {
                    panic!("request")
                };
                assert_eq!(request.rpc_id, sequence.to_string());
                abp_protocol::write_frame(
                    &mut send,
                    &Frame::Response(RpcResponse {
                        rpc_id: request.rpc_id,
                        body_json: "null".into(),
                        ..Default::default()
                    }),
                    MAX_FRAME_BYTES,
                )
                .await
                .unwrap();
            }
            let _ = recv.read_to_end(1).await;
        };
        tokio::join!(client, server);
    })
    .await
    .unwrap();
    a.close().await;
    b.close().await;
}
