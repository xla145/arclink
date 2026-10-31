//! ABP v1 wire framing. Validate the length before allocating the payload.
use prost::Message;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const ALPN: &[u8] = b"agent-bridge/1";
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;
pub const MAX_IO_BYTES: usize = 16 * 1024;
pub const PROTOCOL_MAJOR: u32 = 1;
pub const STREAM_CONTROL: i32 = 1;
pub const STREAM_PAIR: i32 = 2;
pub const STREAM_AGENT_IO: i32 = 3;
pub const CHANNEL_STDIN: i32 = 0;
pub const CHANNEL_STDOUT: i32 = 1;
pub const CHANNEL_STDERR: i32 = 2;
pub const CHANNEL_GAP: i32 = 3;
pub const CHANNEL_EXIT: i32 = 4;

#[derive(Clone, PartialEq, Message)]
pub struct Hello {
    #[prost(uint32, tag = "1")]
    pub major: u32,
    #[prost(uint32, tag = "2")]
    pub minor: u32,
    #[prost(string, tag = "3")]
    pub instance_id: String,
    #[prost(uint32, tag = "4")]
    pub max_frame_bytes: u32,
}
#[derive(Clone, PartialEq, Message)]
pub struct StreamOpen {
    #[prost(int32, tag = "1")]
    pub kind: i32,
    #[prost(string, tag = "2")]
    pub process_id: String,
    #[prost(string, tag = "3")]
    pub generation: String,
    #[prost(uint64, tag = "4")]
    pub cursor: u64,
}
#[derive(Clone, PartialEq, Message)]
pub struct PairRequest {
    #[prost(string, tag = "1")]
    pub session_id: String,
    #[prost(string, tag = "2")]
    pub token: String,
    #[prost(string, tag = "3")]
    pub name: String,
}
#[derive(Clone, PartialEq, Message)]
pub struct RpcRequest {
    #[prost(string, tag = "1")]
    pub rpc_id: String,
    #[prost(string, tag = "2")]
    pub method: String,
    #[prost(string, tag = "3")]
    pub body_json: String,
    #[prost(uint32, tag = "4")]
    pub timeout_ms: u32,
}
#[derive(Clone, PartialEq, Message)]
pub struct RpcResponse {
    #[prost(string, tag = "1")]
    pub rpc_id: String,
    #[prost(string, tag = "2")]
    pub body_json: String,
    #[prost(string, tag = "3")]
    pub error_code: String,
    #[prost(string, tag = "4")]
    pub error_message: String,
}
#[derive(Clone, PartialEq, Message)]
pub struct IoFrame {
    #[prost(int32, tag = "1")]
    pub channel: i32,
    #[prost(bytes = "vec", tag = "2")]
    pub data: Vec<u8>,
    #[prost(uint64, tag = "3")]
    pub cursor: u64,
    #[prost(uint64, tag = "4")]
    pub offset: u64,
    #[prost(uint64, tag = "5")]
    pub lost_bytes: u64,
    #[prost(int32, optional, tag = "6")]
    pub exit_code: Option<i32>,
    /// For gap frames: stdout/stderr if known, 0 for a cross-channel loss.
    #[prost(int32, tag = "7")]
    pub affected_channel: i32,
}
#[derive(Clone, PartialEq, Message)]
pub struct ProtocolError {
    #[prost(string, tag = "1")]
    pub code: String,
    #[prost(string, tag = "2")]
    pub message: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Frame {
    Hello(Hello),
    Open(StreamOpen),
    Pair(PairRequest),
    Request(RpcRequest),
    Response(RpcResponse),
    Io(IoFrame),
    Error(ProtocolError),
}
#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("stream I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid frame length")]
    InvalidLength,
    #[error("unknown frame type")]
    UnknownType,
    #[error("invalid protobuf payload")]
    Decode(#[from] prost::DecodeError),
    #[error("incompatible protocol or invalid peer limits")]
    Incompatible,
}
impl Hello {
    pub fn new(instance_id: impl Into<String>) -> Self {
        Self {
            major: PROTOCOL_MAJOR,
            minor: 0,
            instance_id: instance_id.into(),
            max_frame_bytes: MAX_FRAME_BYTES as u32,
        }
    }
    pub fn negotiate(&self) -> Result<usize, FrameError> {
        if self.major != PROTOCOL_MAJOR
            || self.instance_id.is_empty()
            || self.instance_id.len() > 128
            || self.max_frame_bytes < 1024
        {
            return Err(FrameError::Incompatible);
        }
        Ok((self.max_frame_bytes as usize).min(MAX_FRAME_BYTES))
    }
}
impl Frame {
    fn encode_payload(&self) -> (u8, Vec<u8>) {
        match self {
            Self::Hello(x) => (1, x.encode_to_vec()),
            Self::Open(x) => (2, x.encode_to_vec()),
            Self::Pair(x) => (3, x.encode_to_vec()),
            Self::Request(x) => (4, x.encode_to_vec()),
            Self::Response(x) => (5, x.encode_to_vec()),
            Self::Io(x) => (6, x.encode_to_vec()),
            Self::Error(x) => (7, x.encode_to_vec()),
        }
    }
    pub fn encode(&self, max: usize) -> Result<Vec<u8>, FrameError> {
        let (tag, payload) = self.encode_payload();
        let len = 1 + payload.len();
        if len > max.min(MAX_FRAME_BYTES) {
            return Err(FrameError::InvalidLength);
        }
        let mut bytes = Vec::with_capacity(4 + len);
        bytes.extend_from_slice(&(len as u32).to_be_bytes());
        bytes.push(tag);
        bytes.extend_from_slice(&payload);
        Ok(bytes)
    }
    fn decode_payload(bytes: &[u8]) -> Result<Self, FrameError> {
        let (&tag, payload) = bytes.split_first().ok_or(FrameError::InvalidLength)?;
        Ok(match tag {
            1 => Self::Hello(Hello::decode(payload)?),
            2 => Self::Open(StreamOpen::decode(payload)?),
            3 => Self::Pair(PairRequest::decode(payload)?),
            4 => Self::Request(RpcRequest::decode(payload)?),
            5 => Self::Response(RpcResponse::decode(payload)?),
            6 => Self::Io(IoFrame::decode(payload)?),
            7 => Self::Error(ProtocolError::decode(payload)?),
            _ => return Err(FrameError::UnknownType),
        })
    }
}
/// EOF, including partial header/payload, is an explicit error to the owner.
pub async fn read_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
    max: usize,
) -> Result<Frame, FrameError> {
    let len = reader.read_u32().await? as usize;
    if len == 0 || len > max.min(MAX_FRAME_BYTES) {
        return Err(FrameError::InvalidLength);
    }
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes).await?;
    Frame::decode_payload(&bytes)
}
pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    frame: &Frame,
    max: usize,
) -> Result<(), FrameError> {
    writer.write_all(&frame.encode(max)?).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn fragmented_and_coalesced_frames_preserve_utf8_and_null() {
        let a = Frame::Response(RpcResponse {
            rpc_id: "one".into(),
            body_json: "null".into(),
            ..Default::default()
        });
        let b = Frame::Pair(PairRequest {
            name: "\u{624b}\u{673a}".into(),
            token: "token".into(),
            session_id: "session".into(),
        });
        let mut wire = a.encode(MAX_FRAME_BYTES).unwrap();
        wire.extend(b.encode(MAX_FRAME_BYTES).unwrap());
        let (mut tx, mut rx) = tokio::io::duplex(8);
        let writer = tokio::spawn(async move {
            for chunk in wire.chunks(2) {
                tx.write_all(chunk).await.unwrap();
            }
        });
        assert_eq!(read_frame(&mut rx, MAX_FRAME_BYTES).await.unwrap(), a);
        assert_eq!(read_frame(&mut rx, MAX_FRAME_BYTES).await.unwrap(), b);
        writer.await.unwrap();
    }
    #[tokio::test]
    async fn rejects_lengths_before_reading_or_allocating_payload() {
        for len in [0u32, MAX_FRAME_BYTES as u32 + 1, u32::MAX] {
            let bytes = len.to_be_bytes();
            assert!(matches!(
                read_frame(&mut bytes.as_slice(), MAX_FRAME_BYTES).await,
                Err(FrameError::InvalidLength)
            ));
        }
    }
    #[tokio::test]
    async fn rejects_unknown_malformed_and_truncated() {
        assert!(matches!(
            read_frame(&mut [0, 0, 0, 1, 99].as_slice(), MAX_FRAME_BYTES).await,
            Err(FrameError::UnknownType)
        ));
        assert!(matches!(
            read_frame(&mut [0, 0, 0, 2, 1, 255].as_slice(), MAX_FRAME_BYTES).await,
            Err(FrameError::Decode(_))
        ));
        for input in [&[0, 0][..], &[0, 0, 0, 5, 1][..]] {
            let mut reader = input;
            assert!(matches!(
                read_frame(&mut reader, MAX_FRAME_BYTES).await,
                Err(FrameError::Io(_))
            ));
        }
    }
    #[test]
    fn hello_rejects_incompatible_and_caps_limits() {
        assert_eq!(Hello::new("a").negotiate().unwrap(), MAX_FRAME_BYTES);
        assert!(
            Hello {
                major: 2,
                ..Hello::new("a")
            }
            .negotiate()
            .is_err()
        );
        assert!(
            Hello {
                max_frame_bytes: 0,
                ..Hello::new("a")
            }
            .negotiate()
            .is_err()
        );
        assert_eq!(
            Hello {
                max_frame_bytes: u32::MAX,
                ..Hello::new("a")
            }
            .negotiate()
            .unwrap(),
            MAX_FRAME_BYTES
        );
    }
    #[test]
    fn frozen_hello_tags_and_u64_io_roundtrip() {
        let hello = Hello {
            major: 1,
            minor: 2,
            instance_id: "a".into(),
            max_frame_bytes: 1024,
        };
        assert_eq!(hello.encode_to_vec(), [8, 1, 16, 2, 26, 1, 97, 32, 128, 8]);
        let frame = Frame::Io(IoFrame {
            cursor: u64::MAX,
            offset: u64::MAX,
            data: vec![0, 255],
            ..Default::default()
        });
        let bytes = frame.encode(MAX_FRAME_BYTES).unwrap();
        assert_eq!(Frame::decode_payload(&bytes[4..]).unwrap(), frame);
    }
}
