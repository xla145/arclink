//! Real iroh coverage for the managed project/thread catalog.
use abp_protocol::{self as wire, Frame, PairRequest};
use abp_test_harness::Peer;
use agent_adapters::AdapterSpec;
use agentd::{network::NetworkServer, Daemon};
use iroh::{EndpointAddr, SecretKey};
use serde_json::{json, Value};
use std::sync::Arc;

struct Fixture {
    daemon: Arc<Daemon>,
    server: NetworkServer,
    dir: tempfile::TempDir,
}

impl Fixture {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let daemon = Daemon::open_with_adapters(
            dir.path(),
            vec![AdapterSpec {
                id: "fake".into(),
                name: "Test Agent".into(),
                program: env!("CARGO_BIN_EXE_fake-agent").into(),
                args: Vec::new(),
                verified_version: Some("abp-test-agent 1".into()),
            }],
        )
        .unwrap();
        let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
            .await
            .unwrap();
        Self {
            daemon,
            server,
            dir,
        }
    }

    fn addr(&self) -> EndpointAddr {
        self.server.endpoint().addr()
    }

    async fn pair(&self, name: &str) -> Peer {
        let peer = Peer::connect(self.addr()).await.unwrap();
        let invitation = self.daemon.start_pairing().await.unwrap();
        let mut stream = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
        stream
            .write(Frame::Pair(PairRequest {
                session_id: invitation.session_id,
                token: invitation.token,
                name: name.into(),
            }))
            .await
            .unwrap();
        let pending: Value =
            serde_json::from_str(&stream.response().await.unwrap().body_json).unwrap();
        self.daemon
            .approve_pairing(
                pending["request_id"].as_str().unwrap(),
                ["view", "session"].into_iter().map(str::to_owned).collect(),
            )
            .await
            .unwrap();
        stream.response().await.unwrap();
        peer
    }

    async fn close(self) {
        self.daemon.shutdown().await.unwrap();
        self.server.shutdown().await;
    }
}

#[tokio::test]
async fn managed_catalog_is_authorized_idempotent_and_does_not_spawn() {
    let fixture = Fixture::new().await;
    let phone = fixture.pair("Phone").await;
    let tablet = fixture.pair("Tablet").await;
    let project_path = fixture.dir.path().join("project");
    std::fs::create_dir(&project_path).unwrap();

    let project_request = json!({
        "command_id": "project-create",
        "path": project_path,
        "name": "Shared project"
    });
    let project = phone
        .rpc("projects.create", project_request.clone())
        .await
        .unwrap();
    let retry = phone.rpc("projects.create", project_request).await.unwrap();
    assert_eq!(retry["id"], project["id"]);
    assert!(fixture.daemon.list_processes().await.is_empty());

    let denied = tablet.rpc("projects.list", json!({})).await.unwrap();
    assert!(denied.as_array().unwrap().is_empty());
    let thread_request = json!({
        "command_id": "thread-create",
        "project_id": project["id"],
        "provider_id": "fake",
        "title": "First task"
    });
    assert!(tablet
        .rpc("threads.create", thread_request.clone())
        .await
        .is_err());
    let thread = phone
        .rpc("threads.create", thread_request.clone())
        .await
        .unwrap();
    assert_eq!(
        phone.rpc("threads.create", thread_request).await.unwrap()["id"],
        thread["id"]
    );
    assert_eq!(
        phone
            .rpc("threads.get", json!({"thread_id":thread["id"]}))
            .await
            .unwrap()["id"],
        thread["id"]
    );
    assert!(fixture.daemon.list_processes().await.is_empty());

    fixture
        .daemon
        .grant_managed_project(project["id"].as_str().unwrap(), &tablet.id())
        .await
        .unwrap();
    assert_eq!(
        tablet
            .rpc("threads.list", json!({"project_id":project["id"]}))
            .await
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let snapshot = tablet
        .rpc("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .unwrap();
    assert_eq!(snapshot["thread"]["id"], thread["id"]);
    let replay = tablet.rpc("threads.replay", json!({"environment_id":snapshot["environment_id"], "thread_id":thread["id"], "after_sequence":"0"})).await.unwrap();
    assert_eq!(replay["events"].as_array().unwrap().len(), 1);
    assert_eq!(replay["sequence"], snapshot["sequence"]);
    assert!(tablet
        .rpc(
            "threads.replay",
            json!({"environment_id":"wrong", "thread_id":thread["id"], "after_sequence":"0"})
        )
        .await
        .is_err());
    fixture.daemon.revoke_device(&tablet.id()).await.unwrap();
    assert!(tablet
        .rpc("threads.get", json!({"thread_id":thread["id"]}))
        .await
        .is_err());

    phone.close().await;
    tablet.close().await;
    fixture.close().await;
}
