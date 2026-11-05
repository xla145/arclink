//! Executable discovery and explicit, version-gated launch configuration.
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};

#[derive(Clone, Debug)]
pub struct AdapterSpec {
    pub id: String,
    pub name: String,
    pub program: PathBuf,
    pub args: Vec<String>,
    /// Exact full version output validated by a transport smoke test.
    pub verified_version: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub executable_path: Option<String>,
    pub status: String,
    pub validation: String,
    pub capabilities: Vec<String>,
    pub diagnostic: Option<String>,
}

pub fn discover_specs() -> Vec<AdapterSpec> {
    [
        (
            "claude",
            "Claude Code",
            vec![
                "--print",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
            ],
        ),
        ("codex", "Codex CLI", vec!["app-server", "--stdio"]),
        ("herdr", "Herdr", vec![]),
    ]
    .into_iter()
    .map(|(id, name, args)| AdapterSpec {
        id: id.into(),
        name: name.into(),
        program: find_executable(id).unwrap_or_else(|| PathBuf::from(id)),
        args: args.into_iter().map(String::from).collect(),
        verified_version: None,
    })
    .collect()
}

pub fn find_executable(name: &str) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|v| std::env::split_paths(&v).collect())
        .unwrap_or_default();
    dirs.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
    ]);
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        dirs.extend([home.join(".local/bin"), home.join(".cargo/bin")]);
        if let Ok(entries) = std::fs::read_dir(home.join(".nvm/versions/node")) {
            let mut nodes: Vec<_> = entries.flatten().map(|e| e.path().join("bin")).collect();
            nodes.sort();
            nodes.reverse();
            dirs.extend(nodes);
        }
    }
    dirs.into_iter()
        .map(|d| d.join(name))
        .find(|p| is_executable(p))
}

fn is_executable(path: &Path) -> bool {
    let Ok(meta) = path.metadata() else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.is_file() && meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        meta.is_file()
    }
}

/// Preserve a discovered Node CLI's interpreter location without sourcing a shell.
pub fn command(spec: &AdapterSpec) -> Command {
    let mut command = Command::new(&spec.program);
    if let Some(parent) = spec.program.parent().filter(|p| p.is_absolute()) {
        let mut paths = vec![parent.to_path_buf()];
        paths.extend(
            std::env::var_os("PATH")
                .map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
                .unwrap_or_default(),
        );
        if let Ok(path) = std::env::join_paths(paths) {
            command.env("PATH", path);
        }
    }
    command.kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    command
}

pub async fn probe(spec: &AdapterSpec) -> AgentInfo {
    let mut info = AgentInfo {
        id: spec.id.clone(),
        name: spec.name.clone(),
        version: None,
        executable_path: spec
            .program
            .is_absolute()
            .then(|| spec.program.display().to_string()),
        status: "not_found".into(),
        validation: "unverified".into(),
        capabilities: vec![],
        diagnostic: None,
    };
    if !spec.program.is_absolute() || !is_executable(&spec.program) {
        info.diagnostic = Some("Executable not found; install the CLI and refresh.".into());
        return info;
    }
    let result = probe_version(spec).await;
    match result {
        Ok(version) => {
            let verified = if spec.id == "codex" {
                match probe_codex_transport(spec).await {
                    Ok(()) => true,
                    Err(message) => {
                        info.version = Some(version);
                        info.status = "probe_failed".into();
                        info.validation = "failed".into();
                        info.diagnostic = Some(message);
                        return info;
                    }
                }
            } else {
                spec.verified_version.as_deref() == Some(version.as_str())
            };
            info.version = Some(version);
            info.status = if verified { "available" } else { "installed" }.into();
            if verified {
                info.validation = "verified".into();
                info.capabilities = vec!["stdio".into()];
            } else {
                info.diagnostic = Some(
                    "已检测到安装；ArcLink 尚未验证此 Agent 的接入协议，不代表账号未登录。".into(),
                );
            }
        }
        Err(message) => {
            info.status = "probe_failed".into();
            info.validation = "failed".into();
            info.diagnostic = Some(message);
        }
    }
    info
}

/// Check the exact launch transport without model requests or logging account/thread data.
async fn probe_codex_transport(spec: &AdapterSpec) -> Result<(), String> {
    let mut child = command(spec)
        .args(&spec.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "无法启动 Codex 通信检测，请检查程序路径。".to_owned())?;
    let group = ProbeGroup(child.id());
    let mut input = child.stdin.take().expect("piped stdin");
    let mut output = child.stdout.take().expect("piped stdout");
    let result = tokio::time::timeout(Duration::from_secs(8), async {
        input.write_all(b"{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"arclink_probe\",\"version\":\"0.1.0\"}}}\n")
            .await.map_err(|_| "无法写入 Codex 握手请求。".to_owned())?;
        let mut line = Vec::new();
        let mut total = 0usize;
        loop {
            let byte = output.read_u8().await.map_err(|_| "Codex 在完成握手前退出。".to_owned())?;
            total += 1;
            if total > 64 * 1024 {
                return Err("Codex 握手响应超出限制。".to_owned());
            }
            if byte != b'\n' { line.push(byte); continue; }
            let response: serde_json::Value = serde_json::from_slice(&line)
                .map_err(|_| "Codex 返回了无效的协议响应。".to_owned())?;
            line.clear();
            if response.get("id") != Some(&serde_json::json!(1)) { continue; }
            if response.get("error").is_some()
                || !response.get("result").is_some_and(|r| r.is_object()) {
                return Err("Codex 拒绝了通信握手，请检查版本及本机配置。".to_owned());
            }
            input.write_all(b"{\"method\":\"initialized\"}\n").await
                .map_err(|_| "无法完成 Codex 握手。".to_owned())?;
            return Ok(());
        }
    }).await.unwrap_or_else(|_| Err("Codex 通信检测超时，请检查本机配置后刷新。".to_owned()));
    drop(group);
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

struct ProbeGroup(Option<u32>);
impl Drop for ProbeGroup {
    fn drop(&mut self) {
        terminate_group(self.0);
    }
}

async fn probe_version(spec: &AdapterSpec) -> Result<String, String> {
    let mut child = command(spec)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| "Could not execute version probe.".to_string())?;
    let pid = child.id();
    let mut group = ProbeGroup(pid);
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        let mut output = Vec::new();
        let mut diagnostic = Vec::new();
        let mut stdout = stdout.take(16 * 1024 + 1);
        let mut stderr = stderr.take(16 * 1024 + 1);
        let (out, err) = tokio::join!(
            stdout.read_to_end(&mut output),
            stderr.read_to_end(&mut diagnostic)
        );
        out.map_err(|_| "Version output failed.".to_string())?;
        err.map_err(|_| "Version diagnostics failed.".to_string())?;
        if output.len() > 16 * 1024 || diagnostic.len() > 16 * 1024 {
            return Err("Version output exceeded limit.".into());
        }
        let status = child
            .wait()
            .await
            .map_err(|_| "Version probe did not exit cleanly.".to_string())?;
        if !status.success() {
            return Err("Version command returned an error.".into());
        }
        let version = String::from_utf8(output)
            .map_err(|_| "Version output is not UTF-8.".to_string())?
            .trim()
            .to_owned();
        if version.is_empty() {
            return Err("Version command returned no version.".into());
        }
        Ok(version)
    })
    .await;
    if !matches!(result, Ok(Ok(_))) {
        terminate_group(pid);
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    group.0 = None;
    result.unwrap_or_else(|_| Err("Version probe timed out.".into()))
}

pub fn terminate_group(pid: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = pid {
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
    }
    #[cfg(not(unix))]
    let _ = pid;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn missing_agent_does_not_claim_availability() {
        let spec = AdapterSpec {
            id: "absent".into(),
            name: "Absent".into(),
            program: "/does/not/exist".into(),
            args: vec![],
            verified_version: None,
        };
        let info = probe(&spec).await;
        assert_eq!(info.status, "not_found");
        assert!(info.capabilities.is_empty());
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn exact_evidence_required_for_available() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("agent");
        std::fs::write(&path, "#!/bin/sh\nprintf 'test-agent 1.0\\n'\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut spec = AdapterSpec {
            id: "test".into(),
            name: "Test".into(),
            program: path,
            args: vec![],
            verified_version: None,
        };
        assert_eq!(probe(&spec).await.status, "installed");
        spec.verified_version = Some("test-agent 1.0".into());
        assert_eq!(probe(&spec).await.status, "available");
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn codex_requires_real_handshake_not_a_version_allowlist() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("codex");
        let spec = AdapterSpec {
            id: "codex".into(),
            name: "Codex".into(),
            program: path.clone(),
            args: vec!["app-server".into(), "--stdio".into()],
            verified_version: None,
        };
        for (response, expected) in [
            (r#"{"id":1,"result":{"userAgent":"fixture"}}"#, "available"),
            (r#"{"id":1,"error":{"code":-1}}"#, "probe_failed"),
            (r#"{"id":1,"result":null}"#, "probe_failed"),
            ("invalid-json", "probe_failed"),
        ] {
            let script = format!("#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'codex-cli 99.0.0'; exit; fi\nread request\nprintf '%s\\n' '{}'\nread notification\n", response);
            std::fs::write(&path, script).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            let info = probe(&spec).await;
            assert_eq!(info.status, expected);
            assert_eq!(info.executable_path.as_deref(), path.to_str());
        }
    }
}
