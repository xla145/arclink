//! Opt-in live Claude CLI smoke. It is ignored by default because it needs a
//! logged-in Claude installation and may consume model usage.
#![cfg(unix)]
use agent_adapters::AdapterSpec;
use agentd::Daemon;
use serde_json::{json, Value};
use std::{path::Path, sync::Arc, time::Duration};

fn adapter() -> AdapterSpec {
    agent_adapters::discover_specs()
        .into_iter()
        .find(|spec| spec.id == "claude")
        .expect("Claude adapter is discoverable")
}

async fn snapshot(daemon: &Arc<Daemon>, thread_id: &str) -> Value {
    daemon
        .local_thread_command("threads.snapshot", json!({"thread_id": thread_id}))
        .await
        .expect("snapshot")
}

async fn wait_completed(daemon: &Arc<Daemon>, thread_id: &str, run_id: &str) -> Value {
    for _ in 0..60 {
        let value = snapshot(daemon, thread_id).await;
        if value["runs"]
            .as_array()
            .and_then(|runs| runs.iter().find(|run| run["id"] == run_id))
            .and_then(|run| run["status"].as_str())
            == Some("completed")
        {
            return value;
        }
        if value["runs"]
            .as_array()
            .and_then(|runs| runs.iter().find(|run| run["id"] == run_id))
            .and_then(|run| run["status"].as_str())
            == Some("outcome_unknown")
        {
            panic!("Claude run became outcome_unknown; inspect local Claude CLI configuration");
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    panic!("Claude turn did not complete within the smoke deadline");
}

async fn create_project(daemon: &Arc<Daemon>, cwd: &Path) -> Value {
    daemon
        .local_thread_command(
            "projects.create",
            json!({"command_id":"claude-live-project","path":cwd,"name":"Claude live smoke"}),
        )
        .await
        .expect("project")
}

#[tokio::test]
#[ignore = "requires a logged-in Claude CLI and model network access; run explicitly"]
async fn managed_claude_two_turn_resume_smoke() {
    let directory = tempfile::tempdir().unwrap();
    let cwd = directory.path().join("project");
    std::fs::create_dir_all(&cwd).unwrap();
    let spec = adapter();
    let daemon = Daemon::open_with_adapters(directory.path(), vec![spec.clone()]).unwrap();
    let info = agent_adapters::probe(&spec).await;
    assert_eq!(
        info.validation, "verified",
        "Claude transport unavailable: {:?}",
        info.diagnostic
    );

    let project = create_project(&daemon, &cwd).await;
    let thread = daemon
        .local_thread_command(
            "threads.create",
            json!({"command_id":"claude-live-thread","project_id":project["id"],"provider_id":"claude","title":"Claude live smoke"}),
        )
        .await
        .expect("thread");
    let thread_id = thread["id"].as_str().unwrap();
    let before = snapshot(&daemon, thread_id).await;
    let first_run = daemon
        .local_thread_command(
            "threads.send",
            json!({"command_id":"claude-live-send-1","thread_id":thread_id,"client_message_id":"claude-live-message-1","text":"Reply with exactly the word READY.","expected_revision":null}),
        )
        .await
        .expect("first send");
    let first = wait_completed(&daemon, thread_id, first_run["id"].as_str().unwrap()).await;
    assert!(first["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|message| message["role"] == "assistant"));
    let second_run = daemon
        .local_thread_command(
            "threads.send",
            json!({"command_id":"claude-live-send-1b","thread_id":thread_id,"client_message_id":"claude-live-message-1b","text":"Remember the token ARCLINK-READY and reply with exactly ACK.","expected_revision":null}),
        )
        .await
        .expect("second send");
    let second_before_restart =
        wait_completed(&daemon, thread_id, second_run["id"].as_str().unwrap()).await;
    assert!(
        second_before_restart["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|message| message["role"] == "assistant")
            .count()
            >= 2
    );
    let replay = daemon.local_thread_command("threads.replay", json!({"thread_id":thread_id,"environment_id":before["environment_id"],"after_sequence":before["sequence"]})).await.unwrap();
    assert!(
        replay["events"].as_array().unwrap().iter().any(|event| {
            let message = &event["payload"];
            message["role"] == "assistant"
                && message["content"]["completed"] != true
                && message["content"]["text"]
                    .as_str()
                    .is_some_and(|text| !text.is_empty())
        }),
        "Expected a durable partial assistant event from the actual CLI"
    );
    daemon.shutdown().await.unwrap();
    drop(daemon);

    let reopened = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match Daemon::open_with_adapters(directory.path(), vec![spec.clone()]) {
                Ok(value) => break value,
                Err(error) if error.code == "already_running" => {
                    tokio::time::sleep(Duration::from_millis(50)).await
                }
                Err(error) => panic!("reopen failed: {error:?}"),
            }
        }
    })
    .await
    .expect("daemon should release data ownership after shutdown");
    let third_run = reopened
        .local_thread_command(
            "threads.send",
            json!({"command_id":"claude-live-send-2","thread_id":thread_id,"client_message_id":"claude-live-message-2","text":"Without using tools, reply with only the exact token I asked you to remember earlier.","expected_revision":null}),
        )
        .await
        .expect("resumed send");
    let second = wait_completed(&reopened, thread_id, third_run["id"].as_str().unwrap()).await;
    let messages = second["messages"].as_array().unwrap();
    assert!(
        messages
            .iter()
            .filter(|message| message["role"] == "user")
            .count()
            >= 3
    );
    assert!(
        messages
            .iter()
            .filter(|message| message["role"] == "assistant")
            .count()
            >= 3
    );
    assert!(
        messages
            .iter()
            .rev()
            .find(|message| message["role"] == "assistant" && message["run_id"] == third_run["id"])
            .and_then(|message| message["content"]["text"].as_str())
            .is_some_and(|text| text.contains("ARCLINK-READY")),
        "Resumed Claude session did not retain the prior token"
    );
    reopened.shutdown().await.unwrap();
}
