//! Opt-in native evidence, separate from deterministic recovery regression tests.
use abp_protocol::{self as wire, Frame, Hello, IoFrame, IoResume, PairRequest, StreamOpen};
use abp_test_harness::Peer;
use agentd::{network::NetworkServer, Daemon};
use iroh::{
    endpoint::{RecvStream, SendStream},
    SecretKey,
};
use serde_json::{json, Value};
use std::time::Duration;

struct ChatStream {
    send: SendStream,
    recv: RecvStream,
    buffer: Vec<u8>,
    stdout: u64,
    stderr: u64,
    lease: String,
}
impl ChatStream {
    async fn open(peer: &Peer, process: &Value, resume: Option<IoResume>) -> Self {
        let (mut send, mut recv) = peer.connection.open_bi().await.unwrap();
        wire::write_frame(
            &mut send,
            &Frame::Hello(Hello::new(peer.id())),
            wire::MAX_FRAME_BYTES,
        )
        .await
        .unwrap();
        assert!(matches!(
            wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
                .await
                .unwrap(),
            Frame::Hello(_)
        ));
        let stdout = resume.as_ref().map_or(0, |r| r.stdout_offset);
        let stderr = resume.as_ref().map_or(0, |r| r.stderr_offset);
        wire::write_frame(
            &mut send,
            &Frame::Open(StreamOpen {
                kind: wire::STREAM_AGENT_IO,
                process_id: process["process_id"].as_str().unwrap().into(),
                generation: process["generation"].as_str().unwrap().into(),
                resume,
                record_framed: true,
                ..Default::default()
            }),
            wire::MAX_FRAME_BYTES,
        )
        .await
        .unwrap();
        let Frame::Response(response) = wire::read_frame(&mut recv, wire::MAX_FRAME_BYTES)
            .await
            .unwrap()
        else {
            panic!("chat attach failed")
        };
        assert!(response.error_code.is_empty());
        let body: Value = serde_json::from_str(&response.body_json).unwrap();
        Self {
            send,
            recv,
            buffer: Vec::new(),
            stdout,
            stderr,
            lease: body["lease_id"].as_str().unwrap().into(),
        }
    }
    async fn write(&mut self, value: Value) {
        let mut data = serde_json::to_vec(&value).unwrap();
        data.push(b'\n');
        for chunk in data.chunks(wire::MAX_IO_BYTES) {
            wire::write_frame(
                &mut self.send,
                &Frame::Io(IoFrame {
                    data: chunk.to_vec(),
                    ..Default::default()
                }),
                wire::MAX_FRAME_BYTES,
            )
            .await
            .unwrap();
        }
    }
    async fn next(&mut self) -> Value {
        tokio::time::timeout(Duration::from_secs(90), async {
            loop {
                if let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
                    return serde_json::from_slice(&self.buffer.drain(..=end).collect::<Vec<_>>())
                        .expect("native JSON");
                }
                match wire::read_frame(&mut self.recv, wire::MAX_FRAME_BYTES)
                    .await
                    .unwrap()
                {
                    Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDOUT => {
                        assert_eq!(
                            chunk.offset, self.stdout,
                            "recovery must neither skip nor duplicate bytes"
                        );
                        self.stdout += chunk.data.len() as u64;
                        assert!(self.buffer.len() + chunk.data.len() <= 2 * 1024 * 1024);
                        self.buffer.extend(chunk.data);
                    }
                    Frame::Io(chunk) if chunk.channel == wire::CHANNEL_STDERR => {
                        self.stderr = chunk.offset + chunk.data.len() as u64;
                    }
                    _ => panic!("native output exited, lost bytes or returned a transport error"),
                }
            }
        })
        .await
        .expect("native chat timed out")
    }
    async fn result(&mut self, id: i32) -> Value {
        loop {
            let value = self.next().await;
            if value.get("id") == Some(&json!(id)) {
                assert!(value.get("error").is_none(), "native RPC rejected");
                return value["result"].clone();
            }
        }
    }
    async fn finish_turn(&mut self) -> String {
        let mut answer = String::new();
        for _ in 0..2048 {
            let event = self.next().await;
            assert!(
                event.get("id").is_none(),
                "unexpected tool/approval request in read-only probe"
            );
            if event["method"] == "item/completed"
                && event["params"]["item"]["type"] == "agentMessage"
            {
                answer.push_str(event["params"]["item"]["text"].as_str().unwrap());
            }
            if event["method"] == "turn/completed" {
                assert_eq!(event["params"]["turn"]["status"], "completed");
                assert!(!answer.is_empty());
                return answer;
            }
        }
        panic!("too many native events without completion")
    }
}

fn base64(data: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        out.push(A[((n >> 18) & 63) as usize] as char);
        out.push(A[((n >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            A[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            A[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// Sends a real image, disconnects after native turn acknowledgment, reattaches
/// the SAME process/thread, consumes its reply and sends one further message.
/// Does not print or save native conversation contents.
#[tokio::test]
#[ignore = "requires verified installed Codex, login and model network access"]
async fn real_codex_image_and_connection_recovery() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = Daemon::open(dir.path()).unwrap();
    let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
        .await
        .unwrap();
    let address = server.endpoint().addr();
    let identity = SecretKey::generate();
    let peer = Peer::connect_with_key(address.clone(), identity.clone())
        .await
        .unwrap();
    let invitation = daemon.start_pairing().await.unwrap();
    let mut pair = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
    pair.write(Frame::Pair(PairRequest {
        session_id: invitation.session_id,
        token: invitation.token,
        name: "Image recovery probe".into(),
    }))
    .await
    .unwrap();
    let pending: Value = serde_json::from_str(&pair.response().await.unwrap().body_json).unwrap();
    daemon
        .approve_pairing(
            pending["request_id"].as_str().unwrap(),
            ["view", "session", "task", "approval"]
                .map(String::from)
                .to_vec(),
        )
        .await
        .unwrap();
    pair.response().await.unwrap();
    drop(pair);
    let process = peer.rpc("StartProcess", json!({"operation_id":"native-media-recovery","agent_id":"codex","cwd":dir.path().to_str().unwrap()})).await.unwrap();
    let mut chat = ChatStream::open(&peer, &process, None).await;
    chat.write(json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"arclink_media_probe","version":"0.1.0"}}})).await;
    chat.result(1).await;
    chat.write(json!({"method":"initialized","params":{}}))
        .await;
    chat.write(json!({"id":2,"method":"thread/start","params":{"cwd":dir.path().to_str().unwrap(),"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}})).await;
    let result = chat.result(2).await;
    let thread = result["thread"]["id"].as_str().unwrap();
    let url = format!(
        "data:image/png;base64,{}",
        base64(include_bytes!("../../../fixtures/codex-image-probe.png"))
    );
    assert!(
        url.len() > wire::MAX_IO_BYTES,
        "fixture must span multiple frames"
    );
    chat.write(json!({"id":3,"method":"turn/start","params":{"threadId":thread,"clientUserMessageId":"image-probe-1","sandboxPolicy":{"type":"readOnly"},"input":[{"type":"text","text":"Name only the two dominant colors in this image in English. Do not use tools."},{"type":"image","url":url}]}})).await;
    chat.result(3).await;
    let resume = IoResume {
        stdout_offset: chat.stdout,
        stderr_offset: chat.stderr,
        previous_lease_id: chat.lease.clone(),
    };
    let retained = std::mem::take(&mut chat.buffer);
    peer.close().await;
    drop(chat);
    let peer = Peer::connect_with_key(address, identity).await.unwrap();
    let mut chat = ChatStream::open(&peer, &process, Some(resume)).await;
    chat.buffer = retained;
    let answer = chat.finish_turn().await.to_lowercase();
    assert!(
        answer.contains("red") && answer.contains("blue"),
        "image colors were not recognized"
    );
    chat.write(json!({"id":4,"method":"turn/start","params":{"threadId":thread,"sandboxPolicy":{"type":"readOnly"},"input":[{"type":"text","text":"Reply exactly ARCLINK_RECOVERED. Do not use tools."}]}})).await;
    chat.result(4).await;
    chat.finish_turn().await;
    chat.write(json!({"id":5,"method":"thread/turns/list","params":{"threadId":thread,"limit":1,"sortDirection":"desc","itemsView":"notLoaded"}})).await;
    let page = chat.result(5).await;
    assert_eq!(page["data"].as_array().unwrap().len(), 1);
    assert!(
        page["data"][0]["items"].as_array().unwrap().is_empty(),
        "metadata page must not embed image history"
    );
    assert_eq!(page["data"][0]["status"], "completed");
    chat.write(json!({"id":6,"method":"thread/items/list","params":{"threadId":thread,"turnId":page["data"][0]["id"],"limit":1,"sortDirection":"asc"}})).await;
    let items = chat.result(6).await;
    assert_eq!(items["data"].as_array().unwrap().len(), 1);
    assert_eq!(items["data"][0]["item"]["type"], "userMessage");
    let result = peer.rpc("StopProcess", json!({"operation_id":"native-media-recovery-stop","process_id":process["process_id"],"generation":process["generation"]})).await.unwrap();
    assert_eq!(result["state"], "exited");
    peer.close().await;
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
}
