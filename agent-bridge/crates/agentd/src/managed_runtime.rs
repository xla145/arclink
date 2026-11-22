//! Internal bridge between the service-owned process and provider actor.
//! Authorization and durable turn reservation belong to the application service.
use crate::{
    codex_session::{
        self, SessionError, SessionEvent, SessionHandle, SessionIo, SessionOptions,
        SessionTransport, MAX_TRANSPORT_CHUNK,
    },
    types::ProcessInfo,
    Daemon, IoSession, Result,
};
use agent_adapters::AdapterSpec;
use std::sync::Arc;
use tokio::sync::mpsc;

pub(crate) struct ManagedProvider {
    pub handle: SessionHandle,
    pub events: mpsc::Receiver<SessionEvent>,
    pub process: ProcessInfo,
}

impl Daemon {
    /// Caller must already verify the adapter and authorize the managed Thread.
    /// This is deliberately not an RPC or a client-selected ownership mode.
    pub(crate) async fn start_managed_provider(
        self: &Arc<Self>,
        spec: &AdapterSpec,
        mut options: SessionOptions,
    ) -> Result<ManagedProvider> {
        let mut launch = spec.clone();
        if spec.id == "claude" {
            if let Some(model) = &options.model {
                launch.args.extend(["--model".into(), model.clone()]);
            }
            let resume = options.thread_id.is_some();
            let id = options
                .thread_id
                .get_or_insert_with(|| uuid::Uuid::new_v4().to_string());
            if uuid::Uuid::parse_str(id).is_err() {
                return Err(crate::BridgeError::new(
                    "invalid_params",
                    "Stored Claude session ID is invalid.",
                ));
            }
            launch.args.extend([
                if resume { "--resume" } else { "--session-id" }.into(),
                id.clone(),
            ]);
        }
        let process = self.processes.start_managed(&launch, &options.cwd).await?;
        let session = match self
            .processes
            .attach_managed(&process.process_id, &process.generation)
        {
            Ok(session) => session,
            Err(error) => {
                let _ = self
                    .processes
                    .stop(&process.process_id, &process.generation)
                    .await;
                return Err(error);
            }
        };
        let (transport, io) = SessionTransport::channel();
        let (handle, events) = if spec.id == "claude" {
            crate::claude_session::spawn(options, transport)
        } else {
            codex_session::spawn(options, transport)
        };
        let owner = Arc::downgrade(self);
        let identity = process.clone();
        tokio::spawn(async move {
            pump(session, io).await;
            if let Some(owner) = owner.upgrade() {
                let _ = owner
                    .processes
                    .stop(&identity.process_id, &identity.generation)
                    .await;
            }
        });
        Ok(ManagedProvider {
            handle,
            events,
            process,
        })
    }
}

async fn pump(mut session: IoSession, mut io: SessionIo) {
    // Do not await a full inbound channel while the actor awaits an outbound ACK.
    // Keep at most one drained chunk and continue servicing writes under backpressure.
    let mut pending_output = None;
    loop {
        tokio::select! {
            request = io.from_client.recv() => {
                let Some(request) = request else { break; };
                let result = session.write_record(request.bytes).await
                    .map_err(|_| SessionError::DeliveryUnknown);
                let failed = result.is_err();
                let _ = request.done.send(result);
                if failed { break; }
            }
            capacity = io.to_client.reserve(), if pending_output.is_some() => {
                let Ok(capacity) = capacity else { break; };
                capacity.send(pending_output.take().expect("guarded output"));
            }
            output = session.next(), if pending_output.is_none() => {
                let frame = match output { Ok(Some(frame)) => frame, _ => break };
                // Lost stdout invalidates JSONL framing. Never continue from a
                // partial record or forward stderr as native protocol input.
                if frame.channel != "stdout" { continue; }
                if frame.gap { break; }
                if frame.data.len() > MAX_TRANSPORT_CHUNK { break; }
                pending_output = Some(frame.data);
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{
        codex_protocol::CodexEvent,
        codex_session::{NativeWrite, TurnInput},
    };
    use tokio::{
        sync::oneshot,
        time::{timeout, Duration},
    };

    fn spec(script: &str) -> AdapterSpec {
        AdapterSpec {
            id: "codex".into(),
            name: "Fake Codex".into(),
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            verified_version: None,
        }
    }

    fn protocol_fixture() -> AdapterSpec {
        spec(
            r#"
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*) printf '%s\n' '{"id":"arclink-1","result":{}}' ;;
    *'"method":"thread/start"'*) printf '%s\n' '{"id":"arclink-2","result":{"thread":{"id":"native-thread"}}}' ;;
    *'"method":"turn/start"'*)
      printf '%s\n' '{"id":"arclink-3","result":{"turn":{"id":"native-turn"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"native-thread","turnId":"native-turn","itemId":"message","delta":"hello"}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"native-turn","status":"completed"}}}'
      ;;
  esac
done
"#,
        )
    }

    async fn wait_for_exit(daemon: &Daemon, process: &ProcessInfo) {
        timeout(Duration::from_secs(3), async {
            loop {
                let state = daemon
                    .processes
                    .get(&process.process_id, &process.generation)
                    .unwrap()
                    .state;
                if state == "exited" || state == "failed" {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("managed process must exit when its actor closes");
    }

    #[tokio::test]
    async fn actual_process_handshake_turn_and_drop_cleanup_are_server_owned() {
        let directory = tempfile::tempdir().unwrap();
        let spec = protocol_fixture();
        let daemon = Daemon::open_with_adapters(directory.path(), vec![spec.clone()]).unwrap();
        daemon
            .store
            .grant(
                "phone",
                "Phone",
                vec![
                    "view".into(),
                    "session".into(),
                    "task".into(),
                    "approval".into(),
                ],
            )
            .unwrap();
        let mut runtime = daemon
            .start_managed_provider(
                &spec,
                SessionOptions {
                    cwd: directory.path().to_str().unwrap().into(),
                    thread_id: None,
                    model: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(
            timeout(Duration::from_secs(2), runtime.handle.ready())
                .await
                .unwrap()
                .unwrap(),
            "native-thread"
        );
        assert!(daemon
            .attach_io(
                "phone",
                &runtime.process.process_id,
                &runtime.process.generation
            )
            .await
            .is_err());
        let turn = timeout(
            Duration::from_secs(2),
            runtime.handle.send_turn(TurnInput {
                text: "hello".into(),
                images: vec![],
                client_message_id: "message-1".into(),
            }),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(turn, "native-turn");
        timeout(Duration::from_secs(2), async {
            loop {
                if matches!(
                    runtime.events.recv().await,
                    Some(SessionEvent::Codex(CodexEvent::TurnCompleted { .. }))
                ) {
                    break;
                }
            }
        })
        .await
        .expect("completion must pass through real stdio");
        let process = runtime.process.clone();
        drop(runtime);
        wait_for_exit(&daemon, &process).await;
        daemon.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn output_backpressure_does_not_block_write_ack_or_pump_shutdown() {
        let directory = tempfile::tempdir().unwrap();
        let fixture = spec("dd if=/dev/zero bs=8192 count=64 2>/dev/null; exec cat");
        let daemon = Daemon::open_with_adapters(directory.path(), vec![fixture.clone()]).unwrap();
        let process = daemon
            .processes
            .start_managed(&fixture, directory.path().to_str().unwrap())
            .await
            .unwrap();
        let session = daemon
            .processes
            .attach_managed(&process.process_id, &process.generation)
            .unwrap();
        let (transport, io) = SessionTransport::channel();
        let pump = tokio::spawn(pump(session, io));
        timeout(Duration::from_secs(2), async {
            while transport.from_agent.len() < 32 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("fixture must fill inbound queue");
        let (done, acknowledged) = oneshot::channel();
        transport
            .to_agent
            .send(NativeWrite {
                bytes: b"input\n".to_vec(),
                done,
            })
            .await
            .unwrap();
        timeout(Duration::from_secs(2), acknowledged)
            .await
            .expect("backpressure must not starve outbound writes")
            .unwrap()
            .unwrap();
        drop(transport);
        timeout(Duration::from_secs(2), pump)
            .await
            .expect("closed actor must release pump")
            .unwrap();
        daemon
            .processes
            .stop(&process.process_id, &process.generation)
            .await
            .unwrap();
        daemon.shutdown().await.unwrap();
    }
}
