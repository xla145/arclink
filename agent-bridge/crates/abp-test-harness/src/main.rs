//! Manual pairing probe. Tokens are read from stdin, never command-line arguments.
use abp_protocol::{Frame, PairRequest, STREAM_PAIR};
use abp_test_harness::{Peer, Result};
use iroh::EndpointAddr;
use serde::Deserialize;
use std::io::Read;

#[derive(Deserialize)]
struct Invitation {
    endpoint_id: String,
    session_id: String,
    token: String,
}
#[tokio::main]
async fn main() -> Result<()> {
    eprintln!("Paste one invitation JSON on stdin, then EOF. Approve locally in the desktop pairing window.");
    let mut input = String::new();
    std::io::stdin().take(8193).read_to_string(&mut input)?;
    if input.len() > 8192 {
        return Err("invitation too large".into());
    }
    let invitation: Invitation = serde_json::from_str(&input)?;
    let address = EndpointAddr::new(invitation.endpoint_id.parse()?);
    let peer = Peer::connect(address).await?;
    let mut stream = peer.open(STREAM_PAIR, "", "").await?;
    stream
        .write(Frame::Pair(PairRequest {
            session_id: invitation.session_id,
            token: invitation.token,
            name: "Desktop test peer".into(),
        }))
        .await?;
    stream.response().await?;
    eprintln!("Pair request sent; waiting for local authorization.");
    let response = stream
        .response_with_timeout(std::time::Duration::from_secs(125))
        .await?;
    eprintln!(
        "Authorized response received ({} bytes).",
        response.body_json.len()
    );
    peer.close().await;
    Ok(())
}
