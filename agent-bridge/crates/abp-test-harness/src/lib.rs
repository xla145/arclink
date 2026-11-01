//! Small real-transport peer used by integration tests and manual host validation.
//! It has no mobile session/task/approval implementation and no grant bypass.
use abp_protocol::{self as wire, Frame, Hello, RpcRequest, RpcResponse, StreamOpen};
use iroh::{
    endpoint::{presets, Connection, RecvStream, SendStream},
    Endpoint, EndpointAddr, RelayMode, SecretKey,
};
use serde_json::Value;
use std::time::Duration;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub struct Peer {
    endpoint: Endpoint,
    pub connection: Connection,
}
pub struct Stream {
    pub send: SendStream,
    pub recv: RecvStream,
    max: usize,
    pub lease_id: String,
}
impl Peer {
    pub async fn connect(address: EndpointAddr) -> Result<Self> {
        Self::connect_with_key(address, SecretKey::generate()).await
    }
    pub async fn connect_with_key(address: EndpointAddr, key: SecretKey) -> Result<Self> {
        let mut builder = Endpoint::builder(presets::N0).secret_key(key);
        if address.ip_addrs().next().is_some() {
            builder = builder.relay_mode(RelayMode::Disabled);
        }
        let endpoint = builder.bind().await?;
        let connection = tokio::time::timeout(
            Duration::from_secs(15),
            endpoint.connect(address, wire::ALPN),
        )
        .await??;
        Ok(Self {
            endpoint,
            connection,
        })
    }
    pub fn id(&self) -> String {
        self.endpoint.id().to_string()
    }
    pub async fn open(&self, kind: i32, process_id: &str, generation: &str) -> Result<Stream> {
        self.open_with_limit(kind, process_id, generation, wire::MAX_FRAME_BYTES)
            .await
    }
    pub async fn open_with_limit(
        &self,
        kind: i32,
        process_id: &str,
        generation: &str,
        max_frame_bytes: usize,
    ) -> Result<Stream> {
        self.open_options(
            StreamOpen {
                kind,
                process_id: process_id.into(),
                generation: generation.into(),
                ..Default::default()
            },
            max_frame_bytes,
        )
        .await
    }
    pub async fn open_chat(
        &self,
        process_id: &str,
        generation: &str,
        resume: Option<wire::IoResume>,
    ) -> Result<Stream> {
        self.open_options(
            StreamOpen {
                kind: wire::STREAM_AGENT_IO,
                process_id: process_id.into(),
                generation: generation.into(),
                resume,
                record_framed: true,
                ..Default::default()
            },
            wire::MAX_FRAME_BYTES,
        )
        .await
    }
    async fn open_options(&self, open: StreamOpen, max_frame_bytes: usize) -> Result<Stream> {
        let (send, recv) = self.connection.open_bi().await?;
        let mut stream = Stream {
            send,
            recv,
            max: wire::MAX_FRAME_BYTES,
            lease_id: String::new(),
        };
        stream
            .write(Frame::Hello(Hello {
                max_frame_bytes: max_frame_bytes as u32,
                ..Hello::new(self.id())
            }))
            .await?;
        let Frame::Hello(hello) = stream.read().await? else {
            return Err("server did not negotiate Hello".into());
        };
        stream.max = hello.negotiate()?;
        stream.write(Frame::Open(open)).await?;
        let response = stream.response().await?;
        stream.lease_id = serde_json::from_str::<Value>(&response.body_json)
            .ok()
            .and_then(|v| v["lease_id"].as_str().map(str::to_owned))
            .unwrap_or_default();
        Ok(stream)
    }
    pub async fn rpc(&self, method: &str, body: Value) -> Result<Value> {
        let mut stream = self.open(wire::STREAM_CONTROL, "", "").await?;
        stream
            .write(Frame::Request(RpcRequest {
                rpc_id: "test-1".into(),
                method: method.into(),
                body_json: body.to_string(),
                timeout_ms: 10_000,
            }))
            .await?;
        let response = stream.response().await?;
        let _ = stream.send.finish();
        Ok(serde_json::from_str(&response.body_json)?)
    }
    pub async fn close(self) {
        self.connection.close(0u32.into(), b"peer done");
        self.endpoint.close().await;
    }
}
impl Stream {
    pub async fn write(&mut self, frame: Frame) -> Result<()> {
        tokio::time::timeout(
            Duration::from_secs(10),
            wire::write_frame(&mut self.send, &frame, self.max),
        )
        .await??;
        Ok(())
    }
    pub async fn read(&mut self) -> Result<Frame> {
        self.read_with_timeout(Duration::from_secs(15)).await
    }
    pub async fn read_with_timeout(&mut self, duration: Duration) -> Result<Frame> {
        Ok(tokio::time::timeout(duration, wire::read_frame(&mut self.recv, self.max)).await??)
    }

    pub async fn response(&mut self) -> Result<RpcResponse> {
        self.response_with_timeout(Duration::from_secs(15)).await
    }
    pub async fn response_with_timeout(&mut self, duration: Duration) -> Result<RpcResponse> {
        match self.read_with_timeout(duration).await? {
            Frame::Response(r) if r.error_code.is_empty() => Ok(r),
            Frame::Response(r) => Err(format!("{}: {}", r.error_code, r.error_message).into()),
            Frame::Error(e) => Err(format!("{}: {}", e.code, e.message).into()),
            _ => Err("expected response".into()),
        }
    }
}
