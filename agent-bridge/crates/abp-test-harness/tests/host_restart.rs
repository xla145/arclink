//! Cold-start reconnects must not rely on a warm address-lookup cache or a new QR.
use abp_protocol::{self as wire, Frame, PairRequest};
use abp_test_harness::Peer;
use agentd::{Daemon, network::NetworkServer};
use iroh::{EndpointAddr, SecretKey};
use serde_json::{Value, json};
use std::{
    net::{SocketAddr, UdpSocket},
    time::Duration,
};

fn loopback_address(server: &NetworkServer) -> EndpointAddr {
    let port = server
        .endpoint()
        .bound_sockets()
        .iter()
        .find(|address| address.is_ipv4())
        .unwrap()
        .port();
    EndpointAddr::new(server.endpoint().id()).with_ip_addr(SocketAddr::from(([127, 0, 0, 1], port)))
}

// Endpoint::close() completes before its final background socket owners drop.
// Wait for actual OS release rather than making this test a scheduler race.
async fn reserve_released_port(port: u16) -> UdpSocket {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match UdpSocket::bind(SocketAddr::from(([0, 0, 0, 0], port))) {
                Ok(socket) => return socket,
                Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                Err(error) => panic!("could not reserve released port: {error}"),
            }
        }
    })
    .await
    .expect("host socket was not released")
}

async fn approve(daemon: &Daemon, peer: &Peer) {
    let invitation = daemon.start_pairing().await.unwrap();
    let mut stream = peer.open(wire::STREAM_PAIR, "", "").await.unwrap();
    stream
        .write(Frame::Pair(PairRequest {
            session_id: invitation.session_id,
            token: invitation.token,
            name: "Restart test phone".into(),
        }))
        .await
        .unwrap();
    let pending: Value = serde_json::from_str(&stream.response().await.unwrap().body_json).unwrap();
    daemon
        .approve_pairing(pending["request_id"].as_str().unwrap(), vec!["view".into()])
        .await
        .unwrap();
    stream.response().await.unwrap();
}

#[tokio::test]
async fn cold_phone_and_host_restart_preserve_saved_address_and_pairing() {
    let directory = tempfile::tempdir().unwrap();
    let host_key = SecretKey::generate();
    let phone_key = SecretKey::generate();
    let daemon = Daemon::open_with_adapters(directory.path(), vec![]).unwrap();
    let server = NetworkServer::start(daemon.clone(), host_key.to_bytes(), false)
        .await
        .unwrap();
    let saved_address = loopback_address(&server);
    let peer = Peer::connect_with_key(saved_address.clone(), phone_key.clone())
        .await
        .unwrap();
    approve(&daemon, &peer).await;
    peer.rpc("Ping", json!(null)).await.unwrap();
    peer.close().await;
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
    drop(daemon);
    drop(reserve_released_port(saved_address.ip_addrs().next().unwrap().port()).await);

    // Reopen the durable grant store, and create both endpoints from scratch.
    // Only the saved IP/port and the two original identities survive.
    let daemon = Daemon::open_with_adapters(directory.path(), vec![]).unwrap();
    let server = NetworkServer::start(daemon.clone(), host_key.to_bytes(), false)
        .await
        .unwrap();
    assert_eq!(loopback_address(&server), saved_address);
    let peer = Peer::connect_with_key(saved_address, phone_key)
        .await
        .unwrap();
    peer.rpc("Ping", json!(null)).await.unwrap();
    assert_eq!(daemon.pairing_state().await.state, "idle");
    peer.close().await;
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
}

#[tokio::test]
async fn cold_phone_restart_alone_keeps_the_original_grant() {
    let directory = tempfile::tempdir().unwrap();
    let phone_key = SecretKey::generate();
    let daemon = Daemon::open_with_adapters(directory.path(), vec![]).unwrap();
    let server = NetworkServer::start(daemon.clone(), SecretKey::generate().to_bytes(), false)
        .await
        .unwrap();
    let saved_address = loopback_address(&server);
    let peer = Peer::connect_with_key(saved_address.clone(), phone_key.clone())
        .await
        .unwrap();
    approve(&daemon, &peer).await;
    peer.close().await;

    let peer = Peer::connect_with_key(saved_address, phone_key)
        .await
        .unwrap();
    peer.rpc("Ping", json!(null)).await.unwrap();
    peer.close().await;
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
}

#[tokio::test]
async fn occupied_saved_port_reports_failure_instead_of_changing_the_address() {
    let directory = tempfile::tempdir().unwrap();
    let host_key = SecretKey::generate();
    let daemon = Daemon::open_with_adapters(directory.path(), vec![]).unwrap();
    let server = NetworkServer::start(daemon.clone(), host_key.to_bytes(), false)
        .await
        .unwrap();
    let saved_address = loopback_address(&server);
    let port = saved_address.ip_addrs().next().unwrap().port();
    server.shutdown().await;
    let occupied = reserve_released_port(port).await;
    match NetworkServer::start(daemon.clone(), host_key.to_bytes(), false).await {
        Ok(unexpected) => {
            unexpected.shutdown().await;
            panic!("an occupied saved port must not silently switch to a random port");
        }
        Err(error) => assert_eq!(error.code, "network_error"),
    }
    drop(occupied);
    // Failure must preserve the remembered port so a normal retry can recover.
    let server = NetworkServer::start(daemon.clone(), host_key.to_bytes(), false)
        .await
        .unwrap();
    assert_eq!(loopback_address(&server), saved_address);
    daemon.shutdown().await.unwrap();
    server.shutdown().await;
}
