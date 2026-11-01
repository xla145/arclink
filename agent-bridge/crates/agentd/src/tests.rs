use super::*;
use std::os::unix::fs::PermissionsExt;

fn fixture(dir: &Path, body: &str) -> AdapterSpec {
    let path = dir.join("fixture-agent");
    std::fs::write(&path,format!("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'fixture 1\\n'; exit 0; fi\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    AdapterSpec {
        id: "fixture".into(),
        name: "Fixture".into(),
        program: path,
        args: vec![],
        verified_version: Some("fixture 1".into()),
    }
}
fn daemon(dir: &Path, body: &str) -> Arc<Daemon> {
    let spec = fixture(dir, body);
    let service = Daemon::open_with_adapters(dir.join("data"), vec![spec]).unwrap();
    service.set_network("ready", Some("test-endpoint".into()), None);
    service
}
async fn pair(service: &Daemon, peer: &str) {
    let session = service.start_pairing().await.unwrap();
    let req = service
        .submit_pair(&session.token, peer, "Test device")
        .await
        .unwrap();
    service
        .approve_pairing(
            &req.request_id,
            vec![
                "view".into(),
                "session".into(),
                "task".into(),
                "approval".into(),
            ],
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn pairing_requires_consent_and_token_is_one_use() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    let session = service.start_pairing().await.unwrap();
    let request = service
        .submit_pair(&session.token, "peer", "Phone")
        .await
        .unwrap();
    assert_eq!(
        service.authorize("peer", &["view"]).unwrap_err().code,
        "unauthorized"
    );
    assert!(service
        .submit_pair(&session.token, "other", "Other")
        .await
        .is_err());
    service
        .approve_pairing(&request.request_id, vec!["view".into()])
        .await
        .unwrap();
    service.authorize("peer", &["view"]).unwrap();
    assert!(service.authorize("peer", &["session"]).is_err());
    assert!(service
        .approve_pairing(&request.request_id, vec!["view".into()])
        .await
        .is_err());
}
#[tokio::test]
async fn expired_and_cancelled_pair_requests_cannot_be_approved() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    let session = service.start_pairing().await.unwrap();
    let req = service
        .submit_pair(&session.token, "peer", "Phone")
        .await
        .unwrap();
    service.pairing.lock().await.deadline = Some(Instant::now() - Duration::from_secs(1));
    assert!(service
        .approve_pairing(&req.request_id, vec!["view".into()])
        .await
        .is_err());
    assert_eq!(service.pairing_state().await.state, "expired");
    let next = service.start_pairing().await.unwrap();
    service.cancel_pairing(&next.session_id).await.unwrap();
    assert!(service
        .submit_pair(&next.token, "peer", "Phone")
        .await
        .is_err());
}
#[tokio::test]
async fn cancelled_window_does_not_cancel_replacement() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    let first = service.start_pairing().await.unwrap();
    service.cancel_pairing(&first.session_id).await.unwrap();
    let next = service.start_pairing().await.unwrap();
    assert!(service.cancel_pairing(&first.session_id).await.is_err());
    assert_eq!(
        service.pairing_state().await.session_id,
        Some(next.session_id)
    );
}
#[tokio::test]
async fn start_deduplicates_and_rejects_changed_request() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    let cwd = dir.path().to_str().unwrap();
    let (a, b) = tokio::join!(
        service.start_process("peer", "same", "fixture", cwd),
        service.start_process("peer", "same", "fixture", cwd)
    );
    let a = a.unwrap();
    assert_eq!(a.process_id, b.unwrap().process_id);
    assert_eq!(service.get_status().await.unwrap().active_processes, 1);
    let different = dir.path().join("other");
    std::fs::create_dir(&different).unwrap();
    assert_eq!(
        service
            .start_process("peer", "same", "fixture", different.to_str().unwrap())
            .await
            .unwrap_err()
            .code,
        "conflict"
    );
    service.shutdown().await.unwrap();
    assert_eq!(service.get_status().await.unwrap().active_processes, 0);
}
#[tokio::test]
async fn relay_serializes_large_writes_and_revoke_releases_old_lease() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    let p = service
        .start_process("peer", "start", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    let mut io = service
        .attach_io("peer", &p.process_id, &p.generation)
        .await
        .unwrap();
    assert!(service
        .attach_io("peer", &p.process_id, &p.generation)
        .await
        .is_err());
    let first = vec![b'a'; 12_000];
    let second = vec![b'b'; 12_000];
    let (a, b) = tokio::join!(io.write(first.clone()), io.write(second.clone()));
    a.unwrap();
    b.unwrap();
    let mut output = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while output.len() < 24_000 {
            let frame = io.next().await.unwrap().unwrap();
            assert!(!frame.gap);
            output.extend(frame.data);
        }
    })
    .await
    .unwrap();
    assert!(
        output == [first.clone(), second.clone()].concat() || output == [second, first].concat()
    );
    service.revoke_device("peer").await.unwrap();
    assert!(io.write(vec![b'x']).await.is_err());
    assert_eq!(service.get_status().await.unwrap().active_processes, 1);
    pair(&service, "peer").await;
    assert!(io.write(vec![b'x']).await.is_err());
    let mut reattached = service
        .attach_io("peer", &p.process_id, &p.generation)
        .await
        .unwrap();
    reattached.write(b"after-revoke\n".to_vec()).await.unwrap();
    let mut found = false;
    tokio::time::timeout(Duration::from_secs(5), async {
        while !found {
            let frame = reattached.next().await.unwrap().unwrap();
            found = frame.data.windows(12).any(|w| w == b"after-revoke");
        }
    })
    .await
    .unwrap();
    service.shutdown().await.unwrap();
}
#[tokio::test]
async fn output_overflow_is_bounded_and_reports_gap() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "head -c 6000000 /dev/zero\nexec cat");
    pair(&service, "peer").await;
    let p = service
        .start_process("peer", "start", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut io = service
        .attach_io("peer", &p.process_id, &p.generation)
        .await
        .unwrap();
    let chunk = io.next().await.unwrap().unwrap();
    assert!(chunk.gap);
    assert!(chunk.offset.parse::<u64>().unwrap() > 0);
    service.shutdown().await.unwrap();
}
#[tokio::test]
async fn stale_generation_and_cross_peer_control_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    pair(&service, "other").await;
    let p = service
        .start_process("peer", "start", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    assert!(service
        .attach_io("peer", &p.process_id, "stale")
        .await
        .is_err());
    assert!(service
        .attach_io("other", &p.process_id, &p.generation)
        .await
        .is_err());
    assert!(service
        .stop_process("other", "stop", &p.process_id, &p.generation)
        .await
        .is_err());
    service.shutdown().await.unwrap();
    assert!(service
        .start_process("peer", "after", "fixture", dir.path().to_str().unwrap())
        .await
        .is_err());
}
#[test]
fn duplicate_host_lock_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let _service = Daemon::open(dir.path()).unwrap();
    assert_eq!(Daemon::open(dir.path()).err().unwrap().code, "conflict");
}
#[test]
fn reserved_operation_becomes_unknown_after_store_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("store.sqlite3");
    {
        let store = store::Store::open(&path).unwrap();
        assert!(matches!(
            store.reserve("peer", "op", "fingerprint").unwrap(),
            store::Reservation::New
        ));
    }
    let store = store::Store::open(&path).unwrap();
    assert_eq!(
        store
            .reserve("peer", "op", "fingerprint")
            .err()
            .unwrap()
            .code,
        "outcome_unknown"
    );
    assert_eq!(
        store.reserve("peer", "op", "different").err().unwrap().code,
        "conflict"
    );
}
#[test]
fn independent_store_connections_reserve_only_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("store.sqlite3");
    let one = store::Store::open(&path).unwrap();
    let two = store::Store::open(&path).unwrap();
    let handles: [std::thread::JoinHandle<bool>; 2] = [one, two]
        .map(|store| std::thread::spawn(move || store.reserve("peer", "same", "payload").is_ok()));
    assert_eq!(
        handles
            .into_iter()
            .map(|h| usize::from(h.join().unwrap()))
            .sum::<usize>(),
        1
    );
}

#[tokio::test]
async fn pipe_eof_waits_for_authoritative_process_exit() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec 1>&-\nexec 2>&-\nsleep 1\nexit 7");
    pair(&service, "peer").await;
    let p = service
        .start_process("peer", "start", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    let mut io = service
        .attach_io("peer", &p.process_id, &p.generation)
        .await
        .unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(5), io.next())
        .await
        .unwrap()
        .unwrap()
        .is_none());
    let status = service
        .process_status("peer", &p.process_id, &p.generation)
        .await
        .unwrap();
    assert_eq!(status.state, "exited");
    assert_eq!(status.exit_code, Some(7));
}
#[tokio::test]
async fn duplicate_start_returns_result_even_if_agent_disappears() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    let cwd = dir.path().to_str().unwrap();
    let first = service
        .start_process("peer", "start", "fixture", cwd)
        .await
        .unwrap();
    std::fs::remove_file(dir.path().join("fixture-agent")).unwrap();
    let second = service
        .start_process("peer", "start", "fixture", cwd)
        .await
        .unwrap();
    assert_eq!(first.process_id, second.process_id);
    service.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn snapshots_keep_process_count_and_rows_in_one_revision() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "sleep 0.05\nexit 0");
    pair(&service, "peer").await;
    let cwd = dir.path().to_str().unwrap().to_owned();
    let worker = service.clone();
    let starts = tokio::spawn(async move {
        for i in 0..8 {
            worker
                .start_process("peer", &format!("op-{i}"), "fixture", &cwd)
                .await
                .unwrap();
        }
    });
    for _ in 0..40 {
        let snapshot = service.snapshot().await.unwrap();
        let active = snapshot
            .processes
            .iter()
            .filter(|p| matches!(p.state.as_str(), "starting" | "running" | "stopping"))
            .count() as u32;
        assert_eq!(snapshot.status.active_processes, active);
        tokio::time::sleep(Duration::from_millis(3)).await;
    }
    starts.await.unwrap();
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn snapshots_bound_history_but_old_process_lookup_still_works() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    for i in 0..200 {
        service
            .store
            .save_process(&ProcessInfo {
                process_id: format!("history-{i:03}"),
                generation: "old-generation".into(),
                agent_id: "fixture".into(),
                owner_device_id: "peer".into(),
                pid: None,
                state: "exited".into(),
                started_at: format!("2026-01-01T00:00:{:02}.{:03}Z", i / 100, i % 100),
                exit_code: Some(0),
            })
            .unwrap();
    }
    let p = service
        .start_process("peer", "live", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    let snapshot = service.snapshot().await.unwrap();
    assert!(snapshot.processes.len() <= 65);
    assert_eq!(snapshot.status.active_processes, 1);
    assert!(snapshot
        .processes
        .iter()
        .any(|row| row.process_id == p.process_id));
    assert!(!snapshot
        .processes
        .iter()
        .any(|row| row.process_id == "history-000"));
    assert_eq!(
        service
            .process_status("peer", "history-000", "old-generation")
            .await
            .unwrap()
            .exit_code,
        Some(0)
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn completed_stop_survives_restart_and_preserves_authorization() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    pair(&service, "other").await;
    let process = service
        .start_process("peer", "start", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    let stopped = service
        .stop_process("peer", "stop", &process.process_id, &process.generation)
        .await
        .unwrap();
    assert_eq!(stopped.state, "exited");
    service.shutdown().await.unwrap();
    drop(service);

    let restarted = daemon(dir.path(), "exec cat");
    let replay = restarted
        .stop_process("peer", "stop", &process.process_id, &process.generation)
        .await
        .unwrap();
    assert_eq!(replay, stopped);
    assert_eq!(
        restarted
            .stop_process("peer", "stop", &process.process_id, "changed-generation")
            .await
            .unwrap_err()
            .code,
        "conflict"
    );
    assert_eq!(
        restarted
            .stop_process("other", "stop", &process.process_id, &process.generation)
            .await
            .unwrap_err()
            .code,
        "unauthorized"
    );
    restarted.revoke_device("peer").await.unwrap();
    assert_eq!(
        restarted
            .stop_process("peer", "stop", &process.process_id, &process.generation)
            .await
            .unwrap_err()
            .code,
        "unauthorized"
    );
    restarted.shutdown().await.unwrap();
}

#[tokio::test]
async fn chat_resume_clips_offsets_and_fences_replaced_writer() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(dir.path(), "exec cat");
    pair(&service, "peer").await;
    let p = service
        .start_process("peer", "chat", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    let mut first = service
        .attach_chat_io("peer", &p.process_id, &p.generation, None, true)
        .await
        .unwrap();
    let bytes = "abc你好\n".as_bytes().to_vec();
    first.write_record(bytes.clone()).await.unwrap();
    let frame = tokio::time::timeout(Duration::from_secs(5), first.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(frame.data, bytes);
    let proof = first.lease_id().to_owned();
    let invalid = abp_protocol::IoResume {
        stdout_offset: bytes.len() as u64 + 1,
        stderr_offset: 0,
        previous_lease_id: proof.clone(),
    };
    assert_eq!(
        service
            .attach_chat_io("peer", &p.process_id, &p.generation, Some(&invalid), true)
            .await
            .err()
            .unwrap()
            .code,
        "invalid_params"
    );
    let wrong = abp_protocol::IoResume {
        stdout_offset: 2,
        previous_lease_id: "wrong-proof".into(),
        ..Default::default()
    };
    assert_eq!(
        service
            .attach_chat_io("peer", &p.process_id, &p.generation, Some(&wrong), true)
            .await
            .err()
            .unwrap()
            .code,
        "conflict"
    );
    let resume = abp_protocol::IoResume {
        stdout_offset: 2,
        stderr_offset: 0,
        previous_lease_id: proof,
    };
    let mut second = service
        .attach_chat_io("peer", &p.process_id, &p.generation, Some(&resume), true)
        .await
        .unwrap();
    assert_eq!(
        first.write(b"old\n".to_vec()).await.unwrap_err().code,
        "unauthorized"
    );
    drop(first); // Old Drop must not release the replacement lease.
    let frame = second.next().await.unwrap().unwrap();
    assert_eq!(frame.offset, "2");
    assert_eq!(frame.data, bytes[2..]);
    assert!(!frame.gap);
    second.write_record(b"new\n".to_vec()).await.unwrap();
    let next = tokio::time::timeout(Duration::from_secs(5), second.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(next.offset, bytes.len().to_string());
    assert_eq!(next.data, b"new\n");
    service.revoke_device("peer").await.unwrap();
    assert_eq!(
        second
            .write_record(b"revoked\n".to_vec())
            .await
            .unwrap_err()
            .code,
        "unauthorized"
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn chat_resume_reports_a_fully_evicted_channel_and_exited_output() {
    let dir = tempfile::tempdir().unwrap();
    let service = daemon(
        dir.path(),
        "printf 'lost'; head -c 6000000 /dev/zero >&2; exec cat",
    );
    pair(&service, "peer").await;
    let p = service
        .start_process("peer", "chat-gap", "fixture", dir.path().to_str().unwrap())
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(250)).await;
    let mut io = service
        .attach_chat_io("peer", &p.process_id, &p.generation, None, true)
        .await
        .unwrap();
    let stdout_gap = io.next().await.unwrap().unwrap();
    assert!(stdout_gap.gap);
    assert_eq!(stdout_gap.channel, "stdout");
    assert_eq!(stdout_gap.offset, "4");
    assert!(stdout_gap.data.is_empty());
    let stderr_gap = io.next().await.unwrap().unwrap();
    assert!(stderr_gap.gap);
    assert_eq!(stderr_gap.channel, "stderr");
    assert!(stderr_gap.offset.parse::<u64>().unwrap() > 0);
    let lease = io.lease_id().to_owned();
    service
        .stop_process("peer", "stop-gap", &p.process_id, &p.generation)
        .await
        .unwrap();
    let resume = abp_protocol::IoResume {
        stdout_offset: 4,
        stderr_offset: 6_000_000,
        previous_lease_id: lease,
    };
    let mut ended = service
        .attach_chat_io("peer", &p.process_id, &p.generation, Some(&resume), true)
        .await
        .unwrap();
    assert!(ended.next().await.unwrap().is_none());
    service.shutdown().await.unwrap();
}

#[test]
fn legacy_product_name_upgrades_without_replacing_custom_host_names() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.sqlite");
    let store = store::Store::open(&path).unwrap();
    assert_eq!(store.settings().unwrap().device_name, "ArcLink");
    for (saved, expected) in [("Agent Bridge", "ArcLink"), ("My Mac", "My Mac")] {
        store
            .save_settings(&AppSettings {
                device_name: saved.into(),
            })
            .unwrap();
        let reopened = store::Store::open(&path).unwrap();
        assert_eq!(reopened.settings().unwrap().device_name, expected);
    }
}
