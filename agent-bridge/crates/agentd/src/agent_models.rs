//! Bounded read-only live model discovery; never expose native model instructions.
use crate::agent_projects::{list_agent_models, AgentModel};
use agent_adapters::AdapterSpec;
use serde_json::{json, Value};
use std::{collections::HashSet, path::Path, process::Stdio, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub(crate) async fn list(agent: &str, base: &Path, spec: Option<&AdapterSpec>) -> Vec<AgentModel> {
    if agent == "codex" {
        if let Some(spec) = spec {
            if let Some(models) = live(spec).await {
                return models;
            }
        }
    }
    list_agent_models(agent, base)
}

struct ProcessGroup(Option<u32>);
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.0 {
            // The child owns a new group; cancellation also cleans up descendants.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
}

async fn response(
    output: &mut tokio::process::ChildStdout,
    id: u64,
    budget: &mut usize,
) -> Option<Value> {
    let mut line = Vec::new();
    loop {
        if *budget == 0 {
            return None;
        }
        *budget -= 1;
        let byte = output.read_u8().await.ok()?;
        if byte != b'\n' {
            line.push(byte);
            continue;
        }
        let value: Value = serde_json::from_slice(&line).ok()?;
        line.clear();
        if value.get("id") != Some(&json!(id)) {
            continue;
        }
        if value.get("error").is_some() {
            return None;
        }
        return value.get("result").filter(|v| v.is_object()).cloned();
    }
}

async fn send(input: &mut tokio::process::ChildStdin, value: Value) -> Option<()> {
    let mut bytes = serde_json::to_vec(&value).ok()?;
    bytes.push(b'\n');
    input.write_all(&bytes).await.ok()
}

async fn live(spec: &AdapterSpec) -> Option<Vec<AgentModel>> {
    // Same launch environment as the probe/session: a GUI-launched app has no
    // nvm on PATH, and Codex's `#!/usr/bin/env node` shim would fail silently.
    let mut command = agent_adapters::command(spec);
    command
        .args(&spec.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = command.spawn().ok()?;
    let group = ProcessGroup(child.id());
    let mut input = child.stdin.take()?;
    let mut output = child.stdout.take()?;
    let result = tokio::time::timeout(Duration::from_secs(10), async {
        let mut budget = 4 * 1024 * 1024;
        send(&mut input, json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"arclink_models","version":"0.1.0"}}})).await?;
        response(&mut output, 1, &mut budget).await?;
        send(&mut input, json!({"method":"initialized"})).await?;
        let mut cursor = Value::Null;
        let mut cursors = HashSet::new();
        let mut seen = HashSet::new();
        let mut models = Vec::new();
        for id in 2..=21 {
            send(&mut input, json!({"id":id,"method":"model/list","params":{"cursor":cursor,"limit":100,"includeHidden":false}})).await?;
            let page = response(&mut output, id, &mut budget).await?;
            for model in page.get("data")?.as_array()? {
                if model.get("hidden").and_then(Value::as_bool) == Some(true) { continue; }
                // `model` is the identifier accepted by thread/start and turn/start.
                let slug = model.get("model")?.as_str()?;
                if slug.is_empty() || slug.len() > 160 || !seen.insert(slug.to_owned()) { continue; }
                let name = model.get("displayName").and_then(Value::as_str)
                    .filter(|name| !name.is_empty()).unwrap_or(slug);
                models.push(AgentModel { id: slug.to_owned(), name: name.chars().take(160).collect() });
                if models.len() == 100 { return Some(models); }
            }
            match page.get("nextCursor") {
                None | Some(Value::Null) => return Some(models),
                Some(Value::String(next)) if next.is_empty() => return Some(models),
                Some(Value::String(next)) if cursors.insert(next.clone()) => cursor = json!(next),
                _ => return None,
            }
        }
        None
    }).await.ok().flatten();
    drop(group);
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};

    fn fixture(dir: &Path, body: &str) -> AdapterSpec {
        let program = dir.join("codex");
        fs::write(&program, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        AdapterSpec {
            id: "codex".into(),
            name: "Codex".into(),
            program,
            args: vec![],
            verified_version: None,
        }
    }

    fn cache(dir: &Path) {
        fs::create_dir_all(dir.join(".codex")).unwrap();
        fs::write(
            dir.join(".codex/models_cache.json"),
            r#"{"models":[{"slug":"stale"}]}"#,
        )
        .unwrap();
    }

    #[tokio::test]
    async fn live_catalog_replaces_cache_and_follows_pages() {
        let dir = tempfile::tempdir().unwrap();
        cache(dir.path());
        let spec = fixture(
            dir.path(),
            r#"
read init
case "$init" in *initialize*) ;; *) exit 1;; esac
echo '{"id":1,"result":{}}'
read initialized
read request
case "$request" in *model/list*) ;; *) exit 1;; esac
echo '{"method":"notice","params":{}}'
echo '{"id":2,"result":{"data":[{"id":"opaque","model":"latest","displayName":"Latest","instructions":"PRIVATE"},{"model":"hidden","hidden":true}],"nextCursor":"page2"}}'
read request
case "$request" in *page2*) ;; *) exit 1;; esac
echo '{"id":3,"result":{"data":[{"model":"latest"},{"model":"second","displayName":""}],"nextCursor":null}}'
"#,
        );
        let models = list("codex", dir.path(), Some(&spec)).await;
        assert_eq!(
            models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["latest", "second"]
        );
        assert_eq!(models[0].name, "Latest");
        assert_eq!(models[1].name, "second");
        assert!(!serde_json::to_string(&models).unwrap().contains("PRIVATE"));
    }

    #[tokio::test]
    async fn failed_live_catalog_falls_back_but_successful_empty_does_not() {
        let dir = tempfile::tempdir().unwrap();
        cache(dir.path());
        for (response, expected) in [
            (r#"{"id":2,"error":{"code":-1}}"#, vec!["stale"]),
            (r#"{"id":2,"result":{"data":[]}}"#, vec![]),
            ("invalid", vec!["stale"]),
        ] {
            let spec = fixture(dir.path(), &format!("read init\necho '{{\"id\":1,\"result\":{{}}}}'\nread initialized\nread request\necho '{response}'"));
            let models = list("codex", dir.path(), Some(&spec)).await;
            assert_eq!(
                models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                expected
            );
        }
    }

    #[tokio::test]
    async fn live_catalog_puts_cli_dir_on_path_for_node_shims() {
        // GUI apps inherit a minimal PATH; an nvm `#!/usr/bin/env node` shim
        // needs its own bin dir on PATH, exactly like the session launcher.
        let dir = tempfile::tempdir().unwrap();
        cache(dir.path());
        let spec = fixture(
            dir.path(),
            &format!(
                r#"
case ":$PATH:" in *":{}:"*) ;; *) exit 1;; esac
read init
echo '{{"id":1,"result":{{}}}}'
read initialized
read request
echo '{{"id":2,"result":{{"data":[{{"model":"live"}}],"nextCursor":null}}}}'
"#,
                dir.path().display()
            ),
        );
        let models = list("codex", dir.path(), Some(&spec)).await;
        assert_eq!(models[0].id, "live");
    }

    #[tokio::test]
    async fn repeated_cursor_rejects_partial_catalog() {
        let dir = tempfile::tempdir().unwrap();
        cache(dir.path());
        let spec = fixture(
            dir.path(),
            r#"
read init
echo '{"id":1,"result":{}}'
read initialized
read request
echo '{"id":2,"result":{"data":[{"model":"partial"}],"nextCursor":"same"}}'
read request
echo '{"id":3,"result":{"data":[],"nextCursor":"same"}}'
"#,
        );
        let models = list("codex", dir.path(), Some(&spec)).await;
        assert_eq!(models[0].id, "stale");
    }
}
