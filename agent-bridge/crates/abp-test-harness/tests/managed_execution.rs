//! Real transport acceptance for service-owned Codex sessions.
#![cfg(unix)]
use abp_protocol::{self as wire, Frame, PairRequest};
use abp_test_harness::Peer;
use agent_adapters::AdapterSpec;
use agentd::{network::NetworkServer, Daemon};
use iroh::SecretKey;
use serde_json::{json, Value};
use std::{os::unix::fs::PermissionsExt, sync::Arc, time::Duration};

const PROVIDER: &str = r#"#!/usr/bin/env python3
import json, os, sys, threading, time
if "--version" in sys.argv:
    print("managed-test-codex 1")
    sys.exit(0)
lock = threading.Lock()
native = "native-" + str(os.getpid())
active = None
count = 0
def emit(value):
    with lock:
        print(json.dumps(value), flush=True)
def notify(method, params):
    params["threadId"] = native
    emit({"method":method, "params":params})
def complete(turn, status="completed"):
    global active
    if active != turn: return
    if status == "completed":
        notify("item/agentMessage/delta", {"turnId":turn,"itemId":"answer-"+turn,"delta":"hello"})
        notify("item/completed", {"turnId":turn,"item":{"type":"agentMessage","id":"answer-"+turn,"text":"hello"}})
    notify("turn/completed", {"turn":{"id":turn,"status":status}})
    active = None
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        emit({"id":message["id"],"result":{}})
    elif method in ("thread/start", "thread/resume"):
        native = message.get("params", {}).get("threadId", native)
        emit({"id":message["id"],"result":{"thread":{"id":native}}})
    elif method == "turn/start":
        count += 1
        active = "turn-" + str(count)
        text = message["params"]["input"][0]["text"]
        with open("sent-messages.log","a") as log: log.write(text+"\n")
        with open("session-ids.log","a") as log: log.write(native+"\n")
        emit({"id":message["id"],"result":{"turn":{"id":active}}})
        notify("turn/started", {"turn":{"id":active}})
        if text == "approval":
            emit({"id":"approval-"+active,"method":"item/commandExecution/requestApproval","params":{"threadId":native,"turnId":active,"itemId":"tool-"+active,"command":"echo approved","cwd":os.getcwd()}})
        elif text != "hold":
            threading.Timer(0.3, complete, [active]).start()
    elif method == "turn/interrupt":
        emit({"id":message["id"],"result":{}})
        complete(active, "interrupted")
    elif method is None and "result" in message:
        with open("approvals.log","a") as log: log.write(str(message["id"])+"\n")
        complete(active)
"#;

const CLAUDE_PROVIDER: &str = r#"#!/usr/bin/env python3
import json,sys,threading,os
if "--version" in sys.argv:
    print("managed-test-claude 1"); sys.exit(0)
session="claude-session-"+str(os.getpid())
for flag in ("--session-id","--resume"):
    if flag in sys.argv: session=sys.argv[sys.argv.index(flag)+1]
count=0; active=None; lock=threading.Lock()
def emit(v):
    v.setdefault("session_id",session)
    with lock: print(json.dumps(v),flush=True)
def complete(turn, interrupted=False):
    global active
    if active != turn: return
    if not interrupted:
        emit({"type":"stream_event","event":{"type":"message_start","message":{"id":"answer-"+turn,"content":[]}}})
        emit({"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}})
        emit({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}})
        emit({"type":"assistant","message":{"id":"answer-"+turn,"role":"assistant","content":[{"type":"text","text":"hello"}]}})
    emit({"type":"result","subtype":"success","result":"hello","is_error":False})
    active=None
for line in sys.stdin:
    m=json.loads(line); typ=m.get("type")
    if typ=="control_request":
        sub=m.get("request",{}).get("subtype")
        emit({"type":"control_response","response":{"subtype":"success","request_id":m["request_id"],"response":{}}})
        if sub=="interrupt": complete(active,True)
    elif typ=="user":
        count+=1; active="turn-"+str(count)
        content=m["message"]["content"]
        text=content if isinstance(content,str) else "".join(p.get("text","") for p in content)
        with open("sent-messages.log","a") as log: log.write(text+"\n")
        with open("session-ids.log","a") as log: log.write(session+"\n")
        if text=="approval":
            emit({"type":"control_request","request_id":"approval-"+active,"request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-"+active,"input":{"command":"echo approved"}}})
        elif text!="hold": threading.Timer(0.3,complete,[active]).start()
    elif typ=="control_response":
        with open("approvals.log","a") as log: log.write(str(m["response"]["request_id"])+"\n")
        complete(active)
"#;

struct Fixture {
    daemon: Arc<Daemon>,
    server: NetworkServer,
    dir: tempfile::TempDir,
    adapter: AdapterSpec,
}
impl Fixture {
    async fn new(provider: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("codex-fixture");
        std::fs::write(
            &program,
            if provider == "claude" {
                CLAUDE_PROVIDER
            } else {
                PROVIDER
            },
        )
        .unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let adapter = AdapterSpec {
            id: provider.into(),
            name: "Test Codex".into(),
            program,
            args: vec![],
            verified_version: Some(
                if provider == "claude" {
                    "managed-test-claude 1"
                } else {
                    "managed-test-codex 1"
                }
                .into(),
            ),
        };
        let mut adapters = vec![adapter.clone()];
        if provider == "codex" {
            let claude_program = dir.path().join("claude-fixture");
            std::fs::write(&claude_program, CLAUDE_PROVIDER).unwrap();
            std::fs::set_permissions(&claude_program, std::fs::Permissions::from_mode(0o755))
                .unwrap();
            adapters.push(AdapterSpec {
                id: "claude".into(),
                name: "Test Claude".into(),
                program: claude_program,
                args: vec![],
                verified_version: Some("managed-test-claude 1".into()),
            });
        }
        let daemon = Daemon::open_with_adapters(dir.path(), adapters).unwrap();
        let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
            .await
            .unwrap();
        Self {
            daemon,
            server,
            dir,
            adapter,
        }
    }
    async fn pair(&self, key: SecretKey, name: &str) -> Peer {
        let peer = Peer::connect_with_key(self.server.endpoint().addr(), key)
            .await
            .unwrap();
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
                ["view", "session", "task", "approval"]
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
            )
            .await
            .unwrap();
        stream.response().await.unwrap();
        peer
    }
    async fn create_thread(&self, peer: &Peer, project: &Value, suffix: &str) -> Value {
        peer.rpc("threads.create", json!({"command_id":format!("create-{suffix}"),"project_id":project["id"],"provider_id":self.adapter.id,"title":suffix})).await.unwrap()
    }
}
fn send(thread: &Value, id: &str, text: &str) -> Value {
    json!({"command_id":id,"thread_id":thread["id"],"client_message_id":format!("message-{id}"),"text":text,"expected_revision":null})
}
async fn snapshot(peer: &Peer, thread: &Value) -> Value {
    peer.rpc("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .unwrap()
}
async fn run_status(peer: &Peer, thread: &Value, status: &str) -> Value {
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            let state = snapshot(peer, thread).await;
            if state["runs"]
                .as_array()
                .unwrap()
                .iter()
                .any(|run| run["status"] == status)
            {
                return state;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("expected managed run state")
}

#[tokio::test]
async fn phone_desktop_share_durable_execution_approval_and_recovery() {
    check_shared_execution("codex").await;
}

#[tokio::test]
async fn claude_phone_desktop_share_durable_execution_approval_and_recovery() {
    check_shared_execution("claude").await;
}

async fn check_shared_execution(provider: &str) {
    let fixture = Fixture::new(provider).await;
    let phone_key = SecretKey::generate();
    let phone = fixture.pair(phone_key.clone(), "Phone").await;
    let tablet = fixture.pair(SecretKey::generate(), "Tablet").await;
    let project = phone
        .rpc(
            "projects.create",
            json!({"command_id":"project","path":fixture.dir.path(),"name":"Shared"}),
        )
        .await
        .unwrap();
    let thread = fixture.create_thread(&phone, &project, "normal").await;
    assert!(tablet
        .rpc("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .is_err());
    fixture
        .daemon
        .grant_managed_project(project["id"].as_str().unwrap(), &tablet.id())
        .await
        .unwrap();
    let before = snapshot(&tablet, &thread).await;
    let command = send(&thread, "send-normal", "normal");
    let run = phone.rpc("threads.send", command.clone()).await.unwrap();
    assert_eq!(run["status"], "queued");
    assert_eq!(
        phone.rpc("threads.send", command).await.unwrap()["id"],
        run["id"]
    );
    phone.close().await;
    let completed = run_status(&tablet, &thread, "completed").await;
    assert_eq!(
        completed["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["role"] == "user")
            .count(),
        1
    );
    assert!(completed["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["role"] == "assistant"));
    let phone = Peer::connect_with_key(fixture.server.endpoint().addr(), phone_key)
        .await
        .unwrap();
    let replay=phone.rpc("threads.wait",json!({"environment_id":before["environment_id"],"thread_id":thread["id"],"after_sequence":before["sequence"]})).await.unwrap();
    assert!(!replay["events"].as_array().unwrap().is_empty());
    assert_eq!(
        snapshot(&phone, &thread).await["messages"],
        completed["messages"]
    );
    let desktop = fixture
        .daemon
        .local_thread_command("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .unwrap();
    assert_eq!(desktop["messages"], completed["messages"]);
    assert_eq!(
        std::fs::read_to_string(fixture.dir.path().join("sent-messages.log"))
            .unwrap()
            .lines()
            .count(),
        1
    );

    let approval_thread = fixture.create_thread(&phone, &project, "approval").await;
    fixture
        .daemon
        .local_thread_command(
            "threads.send",
            send(&approval_thread, "desktop-approval", "approval"),
        )
        .await
        .unwrap();
    let pending = tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            let state = snapshot(&phone, &approval_thread).await;
            if !state["approvals"].as_array().unwrap().is_empty() {
                break state;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let approval_id = &pending["approvals"][0]["id"];
    let decision = json!({"command_id":"approve-phone","thread_id":approval_thread["id"],"approval_id":approval_id,"approved":true});
    let competing = json!({"command_id":"approve-desktop","thread_id":approval_thread["id"],"approval_id":approval_id,"approved":true});
    let (phone_result, desktop_result) = tokio::join!(
        phone.rpc("threads.approval", decision.clone()),
        fixture
            .daemon
            .local_thread_command("threads.approval", competing)
    );
    assert_ne!(
        phone_result.is_ok(),
        desktop_result.is_ok(),
        "only one approval decision may execute"
    );
    run_status(&phone, &approval_thread, "completed").await;
    if phone_result.is_ok() {
        phone.rpc("threads.approval", decision).await.unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(fixture.dir.path().join("approvals.log"))
            .unwrap()
            .lines()
            .count(),
        1
    );

    let interrupt_thread = fixture.create_thread(&phone, &project, "interrupt").await;
    phone
        .rpc("threads.send", send(&interrupt_thread, "send-hold", "hold"))
        .await
        .unwrap();
    run_status(&phone, &interrupt_thread, "running").await;
    let stop = json!({"command_id":"stop-desktop","thread_id":interrupt_thread["id"]});
    fixture
        .daemon
        .local_thread_command("threads.interrupt", stop.clone())
        .await
        .unwrap();
    fixture
        .daemon
        .local_thread_command("threads.interrupt", stop)
        .await
        .unwrap();
    run_status(&phone, &interrupt_thread, "interrupted").await;

    let uncertain = fixture.create_thread(&phone, &project, "uncertain").await;
    phone
        .rpc("threads.send", send(&uncertain, "send-uncertain", "hold"))
        .await
        .unwrap();
    run_status(&phone, &uncertain, "running").await;
    fixture.daemon.revoke_device(&tablet.id()).await.unwrap();
    assert!(tablet
        .rpc("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .is_err());
    phone.close().await;
    tablet.close().await;
    let Fixture {
        daemon,
        server,
        dir,
        adapter,
    } = fixture;
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
    drop(daemon);
    let reopened = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match Daemon::open_with_adapters(dir.path(), vec![adapter.clone()]) {
                Ok(d) => break d,
                Err(e) if e.code == "already_running" => {
                    tokio::time::sleep(Duration::from_millis(20)).await
                }
                Err(e) => panic!("{e:?}"),
            }
        }
    })
    .await
    .unwrap();
    let saved = reopened
        .local_thread_command("threads.snapshot", json!({"thread_id":thread["id"]}))
        .await
        .unwrap();
    assert_eq!(saved["messages"], completed["messages"]);
    let recovered = reopened
        .local_thread_command("threads.snapshot", json!({"thread_id":uncertain["id"]}))
        .await
        .unwrap();
    assert_eq!(recovered["runs"][0]["status"], "outcome_unknown");
    assert!(reopened
        .local_thread_command("threads.send", send(&uncertain, "no-replay", "hold"))
        .await
        .is_err());
    assert_eq!(
        std::fs::read_to_string(dir.path().join("sent-messages.log"))
            .unwrap()
            .lines()
            .count(),
        4
    );
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn switches_providers_in_one_timeline_with_fresh_sessions_and_public_handoff() {
    let fixture = Fixture::new("codex").await;
    let phone = fixture.pair(SecretKey::generate(), "Phone").await;
    let other = fixture.pair(SecretKey::generate(), "Other").await;
    let project = phone
        .rpc(
            "projects.create",
            json!({"command_id":"switch-project","path":fixture.dir.path(),"name":"Switch"}),
        )
        .await
        .unwrap();
    let thread = fixture.create_thread(&phone, &project, "switch").await;
    let environment = phone.rpc("environment.describe", json!({})).await.unwrap();
    assert!(environment["capabilities"]
        .as_array()
        .unwrap()
        .contains(&json!("managed_provider_switch_v1")));
    let pick = |id: &str, provider: &str, revision: Value| json!({"command_id":id,"thread_id":thread["id"],"provider_id":provider,"model":null,"expected_revision":revision});
    assert!(other
        .rpc(
            "threads.provider.set",
            pick("unauthorized", "claude", Value::Null)
        )
        .await
        .is_err());
    phone
        .rpc(
            "threads.send",
            send(&thread, "switch-first", "original instruction"),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            if snapshot(&phone, &thread).await["thread"]["status"] == "idle" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let before = snapshot(&phone, &thread).await;
    assert!(phone
        .rpc("threads.provider.set", pick("stale", "claude", json!("0")))
        .await
        .is_err());
    let command = pick(
        "switch-to-claude",
        "claude",
        before["thread"]["revision"].clone(),
    );
    let selected = phone
        .rpc("threads.provider.set", command.clone())
        .await
        .unwrap();
    assert_eq!(selected["id"], thread["id"]);
    assert_eq!(selected["provider_id"], "claude");
    assert_eq!(
        phone.rpc("threads.provider.set", command).await.unwrap(),
        selected
    );
    assert!(phone
        .rpc(
            "threads.provider.set",
            pick("switch-to-claude", "codex", Value::Null)
        )
        .await
        .is_err());
    phone
        .rpc(
            "threads.send",
            send(&thread, "switch-second", "continue with Claude"),
        )
        .await
        .unwrap();
    assert!(phone
        .rpc("threads.provider.set", pick("busy", "codex", Value::Null))
        .await
        .is_err());
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            if snapshot(&phone, &thread).await["thread"]["status"] == "idle" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let selected = phone
        .rpc(
            "threads.provider.set",
            pick("switch-back", "codex", Value::Null),
        )
        .await
        .unwrap();
    assert_eq!(selected["id"], thread["id"]);
    phone
        .rpc(
            "threads.send",
            send(&thread, "switch-third", "continue with Codex"),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            if snapshot(&phone, &thread).await["thread"]["status"] == "idle" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let after = snapshot(&phone, &thread).await;
    let messages = after["messages"].as_array().unwrap();
    assert_eq!(messages.iter().filter(|m| m["role"] == "user").count(), 3);
    assert_eq!(
        messages
            .iter()
            .filter(|m| m["content"]["type"] == "provider_switch")
            .count(),
        2
    );
    assert!(messages
        .iter()
        .any(|m| m["role"] == "assistant" && m["content"]["provider_id"] == "claude"));
    assert!(messages
        .iter()
        .any(|m| m["role"] == "assistant" && m["content"]["provider_id"] == "codex"));
    for old in before["messages"].as_array().unwrap() {
        assert!(messages.contains(old));
    }
    let ids = std::fs::read_to_string(fixture.dir.path().join("session-ids.log")).unwrap();
    let ids: Vec<_> = ids.lines().collect();
    assert_eq!(ids.len(), 3);
    assert_ne!(ids[0], ids[1]);
    assert_ne!(ids[0], ids[2]);
    let sent = std::fs::read_to_string(fixture.dir.path().join("sent-messages.log")).unwrap();
    assert!(sent.contains("<conversation_history>"));
    assert!(sent.contains("original instruction"));
    assert!(sent.contains("continue with Claude"));
    fixture.daemon.shutdown().await.unwrap();
    fixture.server.shutdown().await;
}
