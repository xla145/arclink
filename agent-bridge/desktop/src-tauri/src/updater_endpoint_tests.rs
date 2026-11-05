//! Exercise the real plugin's endpoint selection without contacting production.
//! HTTP is enabled only in this test module for a loopback fixture, never in the
//! shipped configuration; neither download verification nor installation is bypassed.
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};
use tauri_plugin_updater::UpdaterExt;

struct Fixture {
    address: std::net::SocketAddr,
    requests: Arc<Mutex<Vec<String>>>,
    stopped: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    fn new(primary: Option<(u16, String)>, fallback: (u16, String)) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stopped = Arc::new(AtomicBool::new(false));
        let recorded = Arc::clone(&requests);
        let done = Arc::clone(&stopped);
        let thread = thread::spawn(move || {
            while !done.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut socket, _)) => {
                        socket
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut buffer = [0; 4096];
                        let count = socket.read(&mut buffer).unwrap_or(0);
                        if count == 0 {
                            continue;
                        }
                        let request = String::from_utf8_lossy(&buffer[..count]);
                        let path = request.split_whitespace().nth(1).unwrap_or("").to_owned();
                        recorded.lock().unwrap().push(path.clone());
                        let response = if path == "/primary" {
                            primary.as_ref()
                        } else {
                            Some(&fallback)
                        };
                        if let Some((status, body)) = response {
                            let _ = write!(socket, "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                        }
                        // A None response deliberately closes the socket to exercise
                        // the plugin's network-error fallback rather than HTTP errors.
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => panic!("loopback fixture failed: {error}"),
                }
            }
        });
        Self {
            address,
            requests,
            stopped,
            thread: Some(thread),
        }
    }
    fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.address);
        self.thread.take().unwrap().join().unwrap();
    }
}

fn production_config() -> serde_json::Value {
    serde_json::from_str::<serde_json::Value>(include_str!("../tauri.conf.json")).unwrap()
        ["plugins"]["updater"]
        .clone()
}
fn release(version: &str, source: &str) -> String {
    serde_json::json!({
        "version": version,
        "notes": "新增下载加速",
        "platforms": {"darwin-aarch64": {
            "url": format!("https://{source}.example/ArcLink.app.tar.gz"),
            "signature": "fixture-only-check-does-not-download"
        }}
    })
    .to_string()
}
async fn check(
    fixture: &Fixture,
) -> tauri_plugin_updater::Result<Option<tauri_plugin_updater::Update>> {
    let mut config = production_config();
    // Preserve the shipped endpoint count and order while routing each configured
    // source to the corresponding local path. No loopback setting reaches production.
    assert_eq!(config["endpoints"].as_array().unwrap().len(), 2);
    config["endpoints"] = serde_json::json!([
        format!("http://{}/primary", fixture.address),
        format!("http://{}/fallback", fixture.address)
    ]);
    config["dangerousInsecureTransportProtocol"] = true.into();
    let mut context = tauri::test::mock_context(tauri::test::noop_assets());
    context.package_info_mut().version = "0.1.1".parse().unwrap();
    context
        .config_mut()
        .plugins
        .0
        .insert("updater".into(), config);
    let app = tauri::test::mock_builder()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .build(context)
        .unwrap();
    app.handle()
        .updater_builder()
        .timeout(Duration::from_secs(3))
        .no_proxy()
        .target("darwin-aarch64")
        .build()?
        .check()
        .await
}

#[test]
fn shipped_sources_use_r2_then_github_without_weakening_signatures_or_tls() {
    let config = production_config();
    assert_eq!(
        config["endpoints"],
        serde_json::json!([
            "https://download.classktv.com/latest.json",
            "https://github.com/xla145/arclink/releases/latest/download/latest.json"
        ])
    );
    assert_eq!(config["requireSignedVersion"], true);
    for key in [
        "dangerousInsecureTransportProtocol",
        "dangerousAcceptInvalidCerts",
        "dangerousAcceptInvalidHostnames",
        "allowDowngrades",
    ] {
        assert!(!config[key].as_bool().unwrap_or(false));
    }
}

#[tokio::test]
async fn http_failures_network_failure_and_invalid_release_schema_try_github_metadata() {
    for response in [
        Some((404, "missing".into())),
        Some((500, "unavailable".into())),
        None,
        Some((200, "{}".into())),
    ] {
        let fixture = Fixture::new(response, (200, release("9.0.0", "fallback")));
        let update = check(&fixture).await.unwrap().unwrap();
        assert_eq!(update.version, "9.0.0");
        assert_eq!(update.download_url.host_str(), Some("fallback.example"));
        assert_eq!(fixture.requests(), ["/primary", "/fallback"]);
    }
}

#[tokio::test]
async fn valid_r2_metadata_selects_r2_payload_without_querying_github() {
    let fixture = Fixture::new(
        Some((200, release("9.0.0", "primary"))),
        (200, release("10.0.0", "fallback")),
    );
    let update = check(&fixture).await.unwrap().unwrap();
    assert_eq!(update.version, "9.0.0");
    assert_eq!(update.download_url.host_str(), Some("primary.example"));
    assert_eq!(fixture.requests(), ["/primary"]);
}

#[tokio::test]
async fn no_content_or_current_version_stops_without_trying_another_source() {
    for response in [(204, String::new()), (200, release("0.1.1", "primary"))] {
        let fixture = Fixture::new(Some(response), (200, release("9.0.0", "fallback")));
        assert!(check(&fixture).await.unwrap().is_none());
        assert_eq!(fixture.requests(), ["/primary"]);
    }
}

#[tokio::test]
async fn malformed_json_is_an_error_without_plugin_fallback() {
    let fixture = Fixture::new(
        Some((200, "not json".into())),
        (200, release("9.0.0", "fallback")),
    );
    assert!(check(&fixture).await.is_err());
    assert_eq!(fixture.requests(), ["/primary"]);
}
