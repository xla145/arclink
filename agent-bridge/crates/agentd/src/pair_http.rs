//! Short-lived LAN listener so a phone on the same network can return a scanned token.
use crate::{types::BridgeError, Daemon, Result};
use serde::Deserialize;
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::timeout,
};

const WINDOW: Duration = Duration::from_secs(120);

#[derive(Deserialize)]
struct PairBody {
    token: String,
    name: String,
    device_id: String,
}

pub async fn open(daemon: Arc<Daemon>) -> Result<Vec<String>> {
    let listener = TcpListener::bind(("0.0.0.0", 0))
        .await
        .map_err(|_| BridgeError::new("network_error", "Could not open the pairing listener."))?;
    let port = listener
        .local_addr()
        .map_err(|_| BridgeError::new("network_error", "Could not read the pairing port."))?
        .port();
    let urls = advertise(port);
    tokio::spawn(async move {
        let deadline = tokio::time::Instant::now() + WINDOW;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            let accepted = timeout(remaining, listener.accept()).await;
            let Ok(Ok((mut socket, _))) = accepted else {
                break;
            };
            let daemon = daemon.clone();
            tokio::spawn(async move {
                let _ = handle(&daemon, &mut socket).await;
            });
        }
    });
    Ok(urls)
}

fn advertise(port: u16) -> Vec<String> {
    let mut urls = vec![format!("http://127.0.0.1:{port}/pair")];
    if let Some(ip) = default_ipv4() {
        let lan = format!("http://{ip}:{port}/pair");
        if !urls.contains(&lan) {
            urls.push(lan);
        }
    }
    urls
}

fn default_ipv4() -> Option<std::net::Ipv4Addr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("1.1.1.1:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

async fn handle(daemon: &Daemon, socket: &mut tokio::net::TcpStream) -> std::io::Result<()> {
    let mut buffer = vec![0u8; 4096];
    let read = match timeout(Duration::from_secs(5), socket.read(&mut buffer)).await {
        Ok(Ok(n)) => n,
        _ => 0,
    };
    buffer.truncate(read);
    let text = String::from_utf8_lossy(&buffer);
    let body = text.split("\r\n\r\n").nth(1).unwrap_or("");
    let response = match serde_json::from_str::<PairBody>(body) {
        Ok(pair) => match daemon
            .submit_pair(&pair.token, &pair.device_id, &pair.name)
            .await
        {
            Ok(_) => http(200, "{\"ok\":true}"),
            Err(error) => http(401, &json_error(&error.message)),
        },
        Err(_) => http(400, "{\"ok\":false,\"message\":\"invalid pair body\"}"),
    };
    socket.write_all(response.as_bytes()).await?;
    Ok(())
}

fn http(status: u16, body: &str) -> String {
    let reason = if status == 200 { "OK" } else { "Error" };
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn json_error(message: &str) -> String {
    serde_json::json!({"ok": false, "message": message}).to_string()
}
