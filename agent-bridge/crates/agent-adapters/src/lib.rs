//! Executable discovery and explicit, version-gated launch configuration.
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command};

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
            let verified = spec.verified_version.as_deref() == Some(version.as_str());
            info.version = Some(version);
            info.status = if verified {
                "available"
            } else {
                "version_mismatch"
            }
            .into();
            if verified {
                info.validation = "verified".into();
                info.capabilities = vec!["stdio".into()];
            } else {
                info.diagnostic = Some(
                    "Installed version has no verified transport compatibility record.".into(),
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
        assert_eq!(probe(&spec).await.status, "version_mismatch");
        spec.verified_version = Some("test-agent 1.0".into());
        assert_eq!(probe(&spec).await.status, "available");
    }
}
