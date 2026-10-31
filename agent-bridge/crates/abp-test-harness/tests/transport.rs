use abp_protocol::{self as wire, Frame, IoFrame, PairRequest};
use abp_test_harness::{Peer, Stream};
use agent_adapters::AdapterSpec;
use agentd::{network::NetworkServer, Daemon};
use iroh::{EndpointAddr, SecretKey};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

struct Fixture {
    daemon: Arc<Daemon>,
    server: NetworkServer,
    _dir: tempfile::TempDir,
}
impl Fixture {
    async fn new(args: &[&str]) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let spec = AdapterSpec {
            id: "fake".into(),
            name: "Test Agent".into(),
            program: env!("CARGO_BIN_EXE_fake-agent").into(),
            args: args.iter().map(|s| s.to_string()).collect(),
            verified_version: Some("abp-test-agent 1".into()),
        };
        let daemon = Daemon::open_with_adapters(dir.path(), vec![spec]).unwrap();
        let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
            .await
            .unwrap();
        Self {
            daemon,
            server,
            _dir: dir,
        }
    }
    fn addr(&self) -> EndpointAddr {
        self.server.endpoint().addr()
    }
    async fn paired(&self) -> Peer {
        self.paired_with_permissions(&["view", "session", "task", "approval"])
            .await
    }
    async fn paired_with_permissions(&self, permissions: &[&str]) -> Peer {
        let peer = Peer::connect(self.addr()).await.unwrap();
        let invitation = self.daemon.start_pairing().await.unwrap();
        let mut stream = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
        stream
            .write(Frame::Pair(PairRequest {
                session_id: invitation.session_id,
                token: invitation.token,
                name: "Test phone".into(),
            }))
            .await
            .unwrap();
        let pending: Value =
            serde_json::from_str(&stream.response().await.unwrap().body_json).unwrap();
        assert!(
            peer.rpc("Ping", json!({})).await.is_err(),
            "pending is not authorized"
        );
        self.daemon
            .approve_pairing(
                pending["request_id"].as_str().unwrap(),
                permissions
                    .iter()
                    .map(|permission| permission.to_string())
                    .collect(),
            )
            .await
            .unwrap();
        stream.response().await.unwrap();
        peer
    }
    async fn start(&self, peer: &Peer, operation: &str) -> Value {
        peer.rpc("StartProcess", json!({"operation_id":operation,"agent_id":"fake","cwd":self._dir.path().to_str().unwrap()})).await.unwrap()
    }
    async fn close(self) {
        self.daemon.shutdown().await.unwrap();
        self.server.shutdown().await;
    }
}
fn proc_args(process: &Value) -> Value {
    json!({"process_id":process["process_id"],"generation":process["generation"]})
}
async fn io(peer: &Peer, process: &Value) -> Stream {
    peer.open(
        wire::STREAM_AGENT_IO,
        process["process_id"].as_str().unwrap(),
        process["generation"].as_str().unwrap(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn actual_transport_pair_start_dedup_bytes_stop_and_revoke() {
    let f = Fixture::new(&[]).await;
    let stranger = Peer::connect(f.addr()).await.unwrap();
    assert!(stranger.rpc("ListAgents", json!({})).await.is_err());
    stranger.close().await;
    let peer = f.paired().await;
    let p = f.start(&peer, "start-one").await;
    let retry = f.start(&peer, "start-one").await;
    assert_eq!(retry["process_id"], p["process_id"]);
    let changed_cwd = f._dir.path().join("other-cwd");
    std::fs::create_dir(&changed_cwd).unwrap();
    let conflict = peer.rpc("StartProcess", json!({"operation_id":"start-one","agent_id":"fake","cwd":changed_cwd.to_str().unwrap()})).await.unwrap_err();
    assert!(conflict.to_string().contains("conflict"));
    let mut stream = io(&peer, &p).await;
    let bytes = b"opaque\x00\xff native bytes\n".to_vec();
    stream
        .write(Frame::Io(IoFrame {
            data: bytes.clone(),
            ..Default::default()
        }))
        .await
        .unwrap();
    let mut output = Vec::new();
    let mut stderr = Vec::new();
    while output.len() < bytes.len() || stderr.is_empty() {
        match stream.read().await.unwrap() {
            Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDOUT => output.extend(chunk.data),
            Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDERR => stderr.extend(chunk.data),
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(output, bytes);
    assert_eq!(stderr, b"input received\n");
    let mut stop = proc_args(&p);
    stop["operation_id"] = json!("stop-one");
    let stopped = peer.rpc("StopProcess", stop).await.unwrap();
    assert_eq!(stopped["state"], "exited");
    f.daemon.revoke_device(&peer.id()).await.unwrap();
    assert!(peer.rpc("Ping", json!({})).await.is_err());
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn view_only_grant_allows_queries_but_denies_process_and_io_mutations() {
    let f = Fixture::new(&[]).await;
    let peer = f.paired_with_permissions(&["view"]).await;
    assert!(peer.rpc("ListAgents", json!({})).await.is_ok());
    let start = peer
        .rpc(
            "StartProcess",
            json!({"operation_id":"forbidden-start","agent_id":"fake","cwd":f._dir.path().to_str().unwrap()}),
        )
        .await
        .unwrap_err();
    assert!(start.to_string().contains("unauthorized"));
    assert!(peer
        .open(wire::STREAM_AGENT_IO, "unknown", "unknown")
        .await
        .is_err());
    assert!(f.daemon.list_processes().await.is_empty());
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn invitation_replay_and_cancel_never_grant_control() {
    let f = Fixture::new(&[]).await;
    let peer = Peer::connect(f.addr()).await.unwrap();
    let invitation = f.daemon.start_pairing().await.unwrap();
    f.daemon
        .cancel_pairing(&invitation.session_id)
        .await
        .unwrap();
    let mut stream = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
    stream
        .write(Frame::Pair(PairRequest {
            session_id: invitation.session_id,
            token: invitation.token,
            name: "Cancelled".into(),
        }))
        .await
        .unwrap();
    assert!(stream.response().await.is_err());
    let invitation = f.daemon.start_pairing().await.unwrap();
    let request = PairRequest {
        session_id: invitation.session_id,
        token: invitation.token,
        name: "Pending".into(),
    };
    let mut first = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
    first.write(Frame::Pair(request.clone())).await.unwrap();
    first.response().await.unwrap();
    let mut replay = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
    replay.write(Frame::Pair(request)).await.unwrap();
    assert!(replay.response().await.is_err());
    assert!(peer.rpc("Ping", json!({})).await.is_err());
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn revocation_closes_old_connection_even_after_immediate_regrant() {
    let f = Fixture::new(&[]).await;
    let peer = f.paired().await;
    // Let the connection register under its original grant.
    tokio::time::timeout(Duration::from_secs(2), async {
        while f.daemon.get_status().await.unwrap().connected_devices != 1 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    // These uncontended local operations complete without yielding to the
    // connection task, so its queued revoke event sees a renewed current grant.
    f.daemon.revoke_device(&peer.id()).await.unwrap();
    let invitation = f.daemon.start_pairing().await.unwrap();
    let request = f
        .daemon
        .submit_pair(&invitation.token, &peer.id(), "Repaired phone")
        .await
        .unwrap();
    f.daemon
        .approve_pairing(&request.request_id, vec!["view".into()])
        .await
        .unwrap();
    assert!(f.daemon.authorize(&peer.id(), &["view"]).is_ok());
    tokio::time::timeout(Duration::from_secs(2), peer.connection.closed())
        .await
        .expect("a fresh grant must not revive a revoked connection");
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn fragmented_stdin_survives_interleaved_output_and_detach_retains_process() {
    let f = Fixture::new(&["--noisy"]).await;
    let peer = f.paired().await;
    let p = f.start(&peer, "fragment").await;
    let mut stream = io(&peer, &p).await;
    let bytes = b"UNIQUE-ECHO-FRAGMENT\n".to_vec();
    let encoded = Frame::Io(IoFrame {
        data: bytes.clone(),
        ..Default::default()
    })
    .encode(wire::MAX_FRAME_BYTES)
    .unwrap();
    // Output wins server select! while a frame prefix/payload is incomplete.
    stream.send.write_all(&encoded[..2]).await.unwrap();
    assert!(matches!(stream.read().await.unwrap(), Frame::Io(_)));
    stream.send.write_all(&encoded[2..7]).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    stream.send.write_all(&encoded[7..]).await.unwrap();
    let mut output = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !output.windows(bytes.len()).any(|w| w == bytes) {
            if let Frame::Io(chunk) = stream.read().await.unwrap() {
                if chunk.channel == wire::CHANNEL_STDOUT {
                    output.extend(chunk.data);
                }
            }
        }
    })
    .await
    .unwrap();
    drop(stream);
    assert_eq!(
        peer.rpc("GetProcessStatus", proc_args(&p)).await.unwrap()["state"],
        "running"
    );
    f.daemon.revoke_device(&peer.id()).await.unwrap();
    assert!(peer.rpc("GetProcessStatus", proc_args(&p)).await.is_err());
    assert_eq!(f.daemon.list_processes().await[0].state, "running");
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn retained_output_has_gap_and_respects_negotiated_frame_limit() {
    let f = Fixture::new(&["--flood"]).await;
    let peer = f.paired().await;
    let p = f.start(&peer, "flood").await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut stream = peer
        .open_with_limit(
            wire::STREAM_AGENT_IO,
            p["process_id"].as_str().unwrap(),
            p["generation"].as_str().unwrap(),
            1024,
        )
        .await
        .unwrap();
    let mut gap = false;
    let mut received = 0;
    tokio::time::timeout(Duration::from_secs(5), async {
        while received < 64 * 1024 {
            let frame = stream.read().await.unwrap();
            assert!(frame.encode(1024).is_ok());
            if let Frame::Io(chunk) = frame {
                if chunk.channel == wire::CHANNEL_GAP {
                    gap = true;
                    assert!(chunk.lost_bytes > 0);
                } else if chunk.channel == wire::CHANNEL_STDOUT {
                    assert!(gap);
                    assert!(chunk.data.iter().all(|b| *b == b'x'));
                    received += chunk.data.len();
                }
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(received, 64 * 1024);
    peer.close().await;
    f.close().await;
}

#[tokio::test]
async fn ownership_generation_single_writer_and_live_revocation_are_enforced() {
    let f = Fixture::new(&[]).await;
    let first = f.paired().await;
    let p = f.start(&first, "owned").await;
    let second = f.paired().await;
    assert!(second.rpc("GetProcessStatus", proc_args(&p)).await.is_err());
    assert!(second
        .open(
            wire::STREAM_AGENT_IO,
            p["process_id"].as_str().unwrap(),
            p["generation"].as_str().unwrap()
        )
        .await
        .is_err());
    assert!(first
        .open(
            wire::STREAM_AGENT_IO,
            p["process_id"].as_str().unwrap(),
            "old-generation"
        )
        .await
        .is_err());
    let mut active = io(&first, &p).await;
    assert!(first
        .open(
            wire::STREAM_AGENT_IO,
            p["process_id"].as_str().unwrap(),
            p["generation"].as_str().unwrap()
        )
        .await
        .is_err());
    f.daemon.revoke_device(&first.id()).await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(3), active.read())
        .await
        .unwrap();
    assert!(closed.is_err() || matches!(closed, Ok(Frame::Error(_))));
    assert_eq!(f.daemon.list_processes().await[0].state, "running");
    assert!(second.rpc("Ping", json!({})).await.is_ok());
    first.close().await;
    second.close().await;
    f.close().await;
}

/// Explicitly opt in: launches the installed exact-version Codex, but sends no
/// model/task/tool request and never prints or persists returned thread data.
#[tokio::test]
#[ignore = "requires installed verified Codex and native host execution"]
async fn real_codex_initialization_and_read_only_rpc_over_iroh() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = Daemon::open(dir.path()).unwrap();
    let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
        .await
        .unwrap();
    let f = Fixture {
        daemon,
        server,
        _dir: dir,
    };
    let peer = f.paired().await;
    let p = peer.rpc("StartProcess", json!({"operation_id":"native-readonly-probe","agent_id":"codex","cwd":f._dir.path().to_str().unwrap()})).await.expect("verified Codex must start");
    let mut stream = io(&peer, &p).await;
    let initialize = json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent_bridge_transport_probe","version":"0.1.0"},"capabilities":{"experimentalApi":false}}});
    stream
        .write(Frame::Io(IoFrame {
            data: format!("{initialize}\n").into_bytes(),
            ..Default::default()
        }))
        .await
        .unwrap();
    let mut buffer = Vec::new();
    read_native_response(&mut stream, &mut buffer, 1).await;
    let initialized = json!({"method":"initialized"});
    let list = json!({"id":2,"method":"thread/list","params":{"limit":1}});
    stream
        .write(Frame::Io(IoFrame {
            data: format!("{initialized}\n{list}\n").into_bytes(),
            ..Default::default()
        }))
        .await
        .unwrap();
    read_native_response(&mut stream, &mut buffer, 2).await;
    let mut stop = proc_args(&p);
    stop["operation_id"] = json!("native-readonly-stop");
    let result = peer.rpc("StopProcess", stop).await.unwrap();
    assert_eq!(result["state"], "exited");
    peer.close().await;
    f.close().await;
}
async fn read_native_response(stream: &mut Stream, buffer: &mut Vec<u8>, id: i32) {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<_> = buffer.drain(..=end).collect();
                let value: Value =
                    serde_json::from_slice(&line).expect("native response must be JSON");
                if value.get("id") == Some(&json!(id)) {
                    assert!(value.get("error").is_none(), "native RPC returned an error");
                    assert!(value.get("result").is_some(), "native RPC result missing");
                    return;
                }
            }
            match stream.read().await.expect("native output stream failed") {
                Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDOUT => {
                    assert!(
                        buffer.len() + chunk.data.len() <= 1024 * 1024,
                        "native response exceeds bound"
                    );
                    buffer.extend(chunk.data);
                }
                Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDERR => {}
                _ => panic!("native output had a gap or unexpected frame"),
            }
        }
    })
    .await
    .expect("native response timed out");
}
