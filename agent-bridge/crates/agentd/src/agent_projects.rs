//! Reads each Agent's own on-disk project/session records so a paired
//! phone can see what Codex/Claude Code already know about on this Mac.
//! Read-only: never writes to `~/.codex/` or `~/.claude/`, never caches a
//! stale copy that could drift from the files on disk.
use std::io::BufRead;
use std::path::Path;

#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AgentThread {
    pub id: String,
    pub title: String,
    pub updated_at: Option<String>,
    /// Launch origin, independent of whether this imported history is read-only.
    #[serde(default)]
    pub source: Option<String>,
}

/// Display content from a transcript. Roles are user/assistant, explicit
/// public summary, or tool. Private reasoning and system context are omitted.
#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AgentMessage {
    pub role: String,
    pub text: String,
    pub timestamp: Option<String>,
    #[serde(default)]
    pub tool_call_id: Option<String>,
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub tool_phase: Option<String>,
    #[serde(default)]
    pub tool_failed: Option<bool>,
    #[serde(default)]
    pub assistant_phase: Option<String>,
}

#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AgentModel {
    pub id: String,
    pub name: String,
}

/// Only model identifiers and labels, never cached model instructions.
pub fn list_agent_models(agent_id: &str, base: &Path) -> Vec<AgentModel> {
    if agent_id != "codex" {
        return Vec::new();
    }
    let path = base.join(".codex/models_cache.json");
    let Some(bytes) = std::fs::metadata(&path)
        .ok()
        .filter(|m| m.len() <= 4 * 1024 * 1024)
        .and_then(|_| std::fs::read(path).ok())
    else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return Vec::new();
    };
    let mut seen = std::collections::HashSet::new();
    value
        .get("models")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter(|m| m.get("visibility").and_then(serde_json::Value::as_str) != Some("hide"))
        .filter_map(|m| {
            let id = m.get("slug")?.as_str()?;
            if id.is_empty() || id.len() > 160 || !seen.insert(id.to_string()) {
                return None;
            }
            let name = m
                .get("display_name")
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or(id);
            Some(AgentModel {
                id: id.into(),
                name: name.chars().take(160).collect(),
            })
        })
        .take(100)
        .collect()
}

/// One project the Agent itself already tracked on this Mac.
/// `last_seen` is RFC3339. `name` is the Agent's own project name when it
/// has one (Codex desktop projects); Claude Code only has a directory.
/// `threads` are that project's conversations, not separate projects.
#[derive(Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AgentProject {
    pub path: String,
    pub last_seen: Option<String>,
    pub name: Option<String>,
    pub threads: Vec<AgentThread>,
}

/// `base` stands in for the user's home directory; injectable so tests
/// never touch the real one. The RPC handler always calls this with
/// `dirs::home_dir()`.
pub fn list_agent_projects(agent_id: &str, base: &Path) -> Vec<AgentProject> {
    let mut projects = match agent_id {
        "codex" => codex_projects(base),
        "claude" => claude_projects(base),
        _ => Vec::new(),
    };
    projects.sort_by(|a, b| a.path.cmp(&b.path));
    let mut merged: Vec<AgentProject> = Vec::new();
    for project in projects {
        if let Some(previous) = merged
            .last_mut()
            .filter(|previous| previous.path == project.path)
        {
            // Two distinct project registrations can share one directory
            // (typically a rename that left the old registration behind).
            // Prefer whichever one was actually touched more recently rather
            // than an arbitrary pick that depends on object iteration order.
            if project.name.is_some() && project.last_seen > previous.last_seen {
                previous.name = project.name.clone();
            } else if previous.name.is_none() {
                previous.name = project.name.clone();
            }
            previous.last_seen = previous.last_seen.clone().max(project.last_seen);
            previous.threads.extend(project.threads);
        } else {
            merged.push(project);
        }
    }
    for project in &mut merged {
        project.threads.sort_by(|a, b| a.id.cmp(&b.id));
        project.threads.dedup_by(|a, b| a.id == b.id);
        project.threads.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.id.cmp(&b.id))
        });
    }
    merged
}

fn modified_rfc3339(path: &Path) -> Option<String> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(chrono::DateTime::<chrono::Utc>::from(modified).to_rfc3339())
}

/// Named desktop projects and session metadata are separate sources. Desktop
/// assignments win; unassigned CLI/desktop threads use their actual cwd.
fn codex_projects(base: &Path) -> Vec<AgentProject> {
    if let Some(projects) = codex_native_projects(base) {
        return projects;
    }
    let value: serde_json::Value =
        std::fs::read_to_string(base.join(".codex/.codex-global-state.json"))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
    let index = codex_thread_index(base);
    let mut listed: Vec<(String, Vec<String>, AgentProject)> = value
        .get("local-projects")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flatten()
        .filter_map(|(id, project)| {
            let roots: Vec<String> = project
                .get("rootPaths")?
                .as_array()?
                .iter()
                .filter_map(serde_json::Value::as_str)
                .filter(|path| Path::new(path).is_absolute())
                .map(str::to_string)
                .collect();
            let path = roots.first()?.clone();
            Some((
                id.clone(),
                roots,
                AgentProject {
                    path,
                    name: project
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .filter(|name| !name.is_empty())
                        .map(str::to_string),
                    last_seen: project
                        .get("updatedAt")
                        .or_else(|| project.get("createdAt"))
                        .and_then(serde_json::Value::as_i64)
                        .and_then(epoch_ms_to_rfc3339),
                    threads: Vec::new(),
                },
            ))
        })
        .collect();
    let assignments = value
        .get("thread-project-assignments")
        .and_then(serde_json::Value::as_object);
    if let Some(threads) = codex_database_threads(base) {
        for (cwd, mut thread) in threads {
            // Database membership is authoritative: stale assignments must not
            // resurrect deleted, archived or internal subagent threads.
            // Preserve Codex's user-facing/renamed title index. SQLite may
            // retain the original prompt as its title after a desktop rename.
            if let Some((title, _)) = index.get(&thread.id) {
                thread.title = title.clone();
            } else if thread.title.trim().is_empty() {
                thread.title = "未命名对话".into();
            }
            let assigned = assignments
                .and_then(|map| map.get(&thread.id))
                .and_then(|entry| entry.get("projectId"))
                .and_then(serde_json::Value::as_str)
                .and_then(|id| listed.iter().position(|entry| entry.0 == id));
            let matched = assigned.or_else(|| {
                listed
                    .iter()
                    .enumerate()
                    .flat_map(|(i, (_, roots, _))| roots.iter().map(move |root| (i, root)))
                    .filter(|(_, root)| Path::new(&cwd).starts_with(root))
                    .max_by_key(|(_, root)| Path::new(root).components().count())
                    .map(|(i, _)| i)
            });
            let position = match matched {
                Some(i) => i,
                None if Path::new(&cwd).is_absolute() => {
                    // Reuse exact cwd buckets, never turn a previously synthesized
                    // cwd bucket into an ancestor of unrelated session directories.
                    if let Some(i) = listed
                        .iter()
                        .position(|(_, _, project)| project.path == cwd)
                    {
                        i
                    } else {
                        listed.push((
                            String::new(),
                            Vec::new(),
                            AgentProject {
                                path: cwd,
                                name: None,
                                last_seen: None,
                                threads: Vec::new(),
                            },
                        ));
                        listed.len() - 1
                    }
                }
                None => continue,
            };
            let project = &mut listed[position].2;
            if thread.updated_at > project.last_seen {
                project.last_seen = thread.updated_at.clone();
            }
            project.threads.push(thread);
        }
    } else if let Some(assignments) = assignments {
        // Compatibility for old Codex installations without a usable metadata
        // database. Project assignment alone does not establish launch origin.
        for (thread_id, assignment) in assignments {
            let Some(project_id) = assignment
                .get("projectId")
                .and_then(serde_json::Value::as_str)
            else {
                continue;
            };
            let Some((_, _, project)) = listed.iter_mut().find(|entry| entry.0 == project_id)
            else {
                continue;
            };
            let (title, updated_at) = index
                .get(thread_id)
                .cloned()
                .unwrap_or_else(|| ("未命名对话".into(), None));
            project.threads.push(AgentThread {
                id: thread_id.clone(),
                title,
                updated_at,
                source: Some("unknown".into()),
            });
        }
    }
    listed.into_iter().map(|(_, _, project)| project).collect()
}

/// Current Codex project membership supersedes the legacy desktop JSON.
/// An empty project table is authoritative; historical cwd must not resurrect
/// projects removed from the desktop sidebar.
fn codex_native_projects(base: &Path) -> Option<Vec<AgentProject>> {
    let connection = rusqlite::Connection::open_with_flags(
        codex_database_path(base)?,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()?;
    connection
        .busy_timeout(std::time::Duration::from_millis(250))
        .ok()?;
    let mut query = connection
        .prepare("SELECT id, name, updated_at_ms FROM projects ORDER BY position, id")
        .ok()?;
    let rows = query
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .ok()?;
    let mut projects = Vec::new();
    let mut roots_by_project = Vec::new();
    for row in rows {
        let (id, name, updated) = row.ok()?;
        let mut roots_query = connection
            .prepare("SELECT path FROM project_roots WHERE project_id = ?1 ORDER BY position")
            .ok()?;
        let roots = roots_query
            .query_map([&id], |r| r.get::<_, String>(0))
            .ok()?
            .collect::<std::result::Result<Vec<_>, _>>()
            .ok()?;
        let roots: Vec<_> = roots
            .into_iter()
            .filter(|p| Path::new(p).is_absolute())
            .collect();
        let Some(path) = roots.first().cloned() else {
            continue;
        };
        projects.push(AgentProject {
            path,
            name: Some(name),
            last_seen: epoch_ms_to_rfc3339(updated),
            threads: Vec::new(),
        });
        roots_by_project.push((id, roots));
    }
    let index = codex_thread_index(base);
    for (cwd, mut thread) in codex_database_threads(base)? {
        let assignment: Option<String> = connection
            .query_row(
                "SELECT project_id FROM threads WHERE id = ?1",
                [&thread.id],
                |r| r.get(0),
            )
            .ok()?;
        let position = if let Some(id) = assignment {
            // A dangling assignment is a removed project, not a cwd fallback.
            roots_by_project
                .iter()
                .position(|(project_id, _)| *project_id == id)
        } else {
            roots_by_project
                .iter()
                .enumerate()
                .flat_map(|(i, (_, roots))| roots.iter().map(move |root| (i, root)))
                .filter(|(_, root)| Path::new(&cwd).starts_with(root))
                .max_by_key(|(_, root)| Path::new(root).components().count())
                .map(|(i, _)| i)
        };
        if let Some(i) = position {
            if let Some((title, _)) = index.get(&thread.id) {
                thread.title = title.clone();
            }
            let project = &mut projects[i];
            project.last_seen = project.last_seen.clone().max(thread.updated_at.clone());
            project.threads.push(thread);
        }
    }
    Some(projects)
}

fn codex_database_path(base: &Path) -> Option<std::path::PathBuf> {
    std::fs::read_dir(base.join(".codex"))
        .ok()?
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name();
            let version = name
                .to_str()?
                .strip_prefix("state_")?
                .strip_suffix(".sqlite")?
                .parse::<u32>()
                .ok()?;
            Some((version, entry.path()))
        })
        .max_by_key(|(version, _)| *version)
        .map(|(_, path)| path)
}

/// Open only the newest numeric state schema, read-only (including its WAL).
/// Never create a database, checkpoint it, or modify Codex's records.
fn codex_database_threads(base: &Path) -> Option<Vec<(String, AgentThread)>> {
    let path = codex_database_path(base)?;
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    connection
        .busy_timeout(std::time::Duration::from_millis(250))
        .ok()?;
    let mut query = connection
        .prepare(
            "SELECT id, cwd, title, updated_at, source FROM threads WHERE archived = 0 ORDER BY id",
        )
        .ok()?;
    let rows = query
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .ok()?;
    let mut threads = Vec::new();
    for row in rows {
        let (id, cwd, title, updated, source) = row.ok()?;
        if source.starts_with("subagent")
            || serde_json::from_str::<serde_json::Value>(&source)
                .ok()
                .is_some_and(|value| value.get("subagent").is_some())
        {
            continue;
        }
        let source = match source.as_str() {
            "cli" | "exec" => "cli",
            "vscode" | "desktop" => "desktop",
            _ => "unknown",
        };
        threads.push((
            cwd,
            AgentThread {
                id,
                title,
                updated_at: chrono::DateTime::from_timestamp(updated, 0)
                    .map(|date| date.to_rfc3339()),
                source: Some(source.into()),
            },
        ));
    }
    Some(threads)
}

/// Last `session_index.jsonl` row wins. That file is Codex's own thread
/// title index; thread ids are joined onto projects through
/// `thread-project-assignments` in the global state.
fn codex_thread_index(base: &Path) -> std::collections::HashMap<String, (String, Option<String>)> {
    let mut index = std::collections::HashMap::new();
    let Ok(file) = std::fs::File::open(base.join(".codex/session_index.jsonl")) else {
        return index;
    };
    for line in std::io::BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let Some(id) = value.get("id").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let title = value
            .get("thread_name")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .unwrap_or("未命名对话");
        let updated_at = value
            .get("updated_at")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        index.insert(id.to_string(), (title.to_string(), updated_at));
    }
    index
}

fn epoch_ms_to_rfc3339(ms: i64) -> Option<String> {
    let secs = ms.div_euclid(1000);
    let nanos = (ms.rem_euclid(1000) as u32) * 1_000_000;
    chrono::DateTime::from_timestamp(secs, nanos).map(|time| time.to_rfc3339())
}

/// Reads one conversation's user/assistant messages by thread id. Codex
/// stores each thread as a `.jsonl.zst` rollout whose filename embeds the
/// thread id; Claude Code as `~/.claude/projects/<dir>/<thread-id>.jsonl`.
/// Images, explicit public reasoning summaries and tool records are retained;
/// private reasoning and environment/system prompts are never returned.
pub fn list_thread_messages(agent_id: &str, thread_id: &str, base: &Path) -> Vec<AgentMessage> {
    let messages = match agent_id {
        "codex" => codex_thread_messages(thread_id, base),
        "claude" => claude_thread_messages(thread_id, base),
        _ => Vec::new(),
    };
    bounded_history(messages)
}

// GetThreadMessages returns one Control response, not a paginated stream.
// Reserve room below the protocol's 1 MiB limit for response metadata.
const HISTORY_JSON_BUDGET: usize = 900_000;
const MESSAGE_TEXT_JSON_BUDGET: usize = 256_000;

fn bounded_history(mut messages: Vec<AgentMessage>) -> Vec<AgentMessage> {
    let encoded_len = |message: &AgentMessage| {
        serde_json::to_vec(message)
            .map(|json| json.len())
            .unwrap_or(usize::MAX)
    };
    let total = messages
        .iter()
        .map(&encoded_len)
        .fold(2usize, |size, length| {
            size.saturating_add(length).saturating_add(1)
        });
    if total < HISTORY_JSON_BUDGET {
        return messages;
    }

    // Preserve turns while reducing images first. The placeholder retains an
    // image-only turn and never copies its path/data into visible diagnostics.
    for message in &mut messages {
        message.text = omit_embedded_history_images(&message.text);
        message.text = bounded_message_text(&message.text);
    }
    let notice = AgentMessage {
        role: "assistant".into(),
        text: "此对话较长，当前仅显示部分记录；部分图片或内容已省略，完整记录请在 Mac 查看。"
            .into(),
        timestamp: None,
        tool_call_id: None,
        tool_name: None,
        tool_phase: None,
        tool_failed: None,
        assistant_phase: None,
    };
    let mut used = 2 + encoded_len(&notice) + 1;
    let mut retained = Vec::new();
    for message in messages.into_iter().rev() {
        let size = encoded_len(&message).saturating_add(1);
        if used.saturating_add(size) >= HISTORY_JSON_BUDGET {
            break;
        }
        used += size;
        retained.push(message);
    }
    retained.push(notice);
    retained.reverse();
    retained
}

fn omit_embedded_history_images(text: &str) -> String {
    let mut remainder = text;
    let mut result = String::new();
    let prefix = "![图片](data:image/";
    while let Some(start) = remainder.find(prefix) {
        result.push_str(&remainder[..start]);
        let image = &remainder[start..];
        let Some(end) = image.find(')') else {
            result.push_str(image);
            return result;
        };
        result.push_str("[图片无法显示：对话过长，内嵌图片请在 Mac 查看]");
        remainder = &image[end + 1..];
    }
    result.push_str(remainder);
    result
}

fn bounded_message_text(text: &str) -> String {
    let mut json_bytes = 0;
    for (index, character) in text.char_indices() {
        // JSON escapes quotes, backslashes and controls; count encoded bytes rather
        // than raw UTF-8 so dense control/tool output cannot overflow a frame.
        let cost = match character {
            '"' | '\\' | '\n' | '\r' | '\t' | '\u{08}' | '\u{0c}' => 2,
            value if value <= '\u{1f}' => 6,
            value => value.len_utf8(),
        };
        if json_bytes + cost > MESSAGE_TEXT_JSON_BUDGET {
            return format!("{}\n[内容已截短，完整记录请在 Mac 查看]", &text[..index]);
        }
        json_bytes += cost;
    }
    text.into()
}

fn codex_thread_messages(thread_id: &str, base: &Path) -> Vec<AgentMessage> {
    // Ids embed a timestamp; strip any dotted suffix before matching files.
    let clean = thread_id.split('.').next().unwrap_or(thread_id);
    let sessions = base.join(".codex/sessions");
    let mut files = Vec::new();
    collect_files(&sessions, &mut files);
    let Some(file) = files.into_iter().find(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains(clean))
    }) else {
        return Vec::new();
    };
    let Ok(opened) = std::fs::File::open(&file) else {
        return Vec::new();
    };
    let reader: Box<dyn std::io::Read> =
        if file.extension().is_some_and(|extension| extension == "zst") {
            match zstd::Decoder::new(opened) {
                Ok(reader) => Box::new(reader),
                Err(_) => return Vec::new(),
            }
        } else {
            Box::new(opened)
        };
    let mut messages = Vec::new();
    for line in std::io::BufReader::new(reader)
        .lines()
        .map_while(Result::ok)
    {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if value.get("type").and_then(serde_json::Value::as_str) != Some("response_item") {
            continue;
        }
        let Some(payload) = value.get("payload") else {
            continue;
        };
        let timestamp = value
            .get("timestamp")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        let kind = payload
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        if kind == "reasoning" {
            // Only the provider's explicit public summary; never content,
            // encrypted_content, thinking, or other private reasoning fields.
            let text = flatten_content(payload.get("summary"));
            push_message(&mut messages, "summary", text, &timestamp);
            continue;
        }
        if matches!(kind, "function_call" | "custom_tool_call") {
            let name = payload
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("工具调用");
            let input = payload.get("arguments").or_else(|| payload.get("input"));
            if let Some(input) = input {
                push_tool_message(
                    &mut messages,
                    tool_text(name, input),
                    &timestamp,
                    payload.get("call_id"),
                    Some(name),
                    "input",
                    None,
                );
            }
            continue;
        }
        if matches!(kind, "function_call_output" | "custom_tool_call_output") {
            let text = flatten_content(payload.get("output"));
            push_tool_message(
                &mut messages,
                text,
                &timestamp,
                payload.get("call_id"),
                None,
                "output",
                codex_tool_failure(payload),
            );
            continue;
        }
        let role = payload
            .get("role")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        if role != "user" && role != "assistant" {
            continue;
        }
        let before = messages.len();
        push_message(
            &mut messages,
            role,
            flatten_content(payload.get("content")),
            &timestamp,
        );
        for message in &mut messages[before..] {
            if message.role == "assistant" {
                message.assistant_phase = assistant_phase(payload);
            }
        }
    }
    messages
}

/// Claude Code transcripts are plain `.jsonl`: one record per line, user
/// and assistant turns under `type`/`message.content`.
fn claude_thread_messages(thread_id: &str, base: &Path) -> Vec<AgentMessage> {
    let clean = thread_id.split('.').next().unwrap_or(thread_id);
    let projects = base.join(".claude/projects");
    let mut files = Vec::new();
    collect_files(&projects, &mut files);
    let Some(file) = files.into_iter().find(|path| {
        path.file_stem()
            .and_then(|stem| stem.to_str())
            .is_some_and(|stem| stem == clean)
    }) else {
        return Vec::new();
    };
    let reader = match std::fs::File::open(&file) {
        Ok(reader) => reader,
        Err(_) => return Vec::new(),
    };
    let mut messages = Vec::new();
    for line in std::io::BufReader::new(reader)
        .lines()
        .map_while(Result::ok)
    {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let kind = value
            .get("type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        if kind != "user" && kind != "assistant" {
            continue;
        }
        let content = value.get("message").and_then(|m| m.get("content"));
        let timestamp = value
            .get("timestamp")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        let before = messages.len();
        if let Some(parts) = content.and_then(serde_json::Value::as_array) {
            // Preserve ordering: do not merge a tool result into a user's
            // request or expose Claude's private `thinking` blocks.
            let mut prose = Vec::new();
            for part in parts {
                let part_kind = part
                    .get("type")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if matches!(part_kind, "tool_use" | "tool_result") {
                    push_message(&mut messages, kind, prose.join("\n"), &timestamp);
                    prose.clear();
                    let text = if part_kind == "tool_use" {
                        let name = part
                            .get("name")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("工具调用");
                        part.get("input")
                            .map(|input| tool_text(name, input))
                            .unwrap_or_default()
                    } else {
                        flatten_content(part.get("content"))
                    };
                    let is_input = part_kind == "tool_use";
                    push_tool_message(
                        &mut messages,
                        text,
                        &timestamp,
                        part.get(if is_input { "id" } else { "tool_use_id" }),
                        part.get("name").and_then(serde_json::Value::as_str),
                        if is_input { "input" } else { "output" },
                        if is_input {
                            None
                        } else {
                            structured_tool_failure(part)
                        },
                    );
                } else {
                    let text = flatten_part(part);
                    if !text.is_empty() {
                        prose.push(text);
                    }
                }
            }
            push_message(&mut messages, kind, prose.join("\n"), &timestamp);
        } else {
            push_message(&mut messages, kind, flatten_content(content), &timestamp);
        }
        for message in &mut messages[before..] {
            if message.role == "assistant" {
                message.assistant_phase = value.get("message").and_then(assistant_phase);
            }
        }
    }
    messages
}

/// Display phase comes only from explicit provider metadata. Legacy/unknown
/// values remain unknown; content text is never a classification signal.
fn assistant_phase(value: &serde_json::Value) -> Option<String> {
    ["phase", "channel"].into_iter().find_map(|key| {
        match value.get(key).and_then(serde_json::Value::as_str) {
            Some("commentary") => Some("commentary".into()),
            Some("final_answer" | "final") => Some("final_answer".into()),
            _ => None,
        }
    })
}

/// Only native result metadata is authoritative. Never search prose for error words
/// or descend into a command's arbitrary `output`/`content` text.
fn structured_tool_failure(value: &serde_json::Value) -> Option<bool> {
    structured_tool_outcome(value).flatten()
}

// The outer Option distinguishes narrative from a recognized but unfinished result.
fn structured_tool_outcome(value: &serde_json::Value) -> Option<Option<bool>> {
    let flags = ["is_error", "isError"]
        .into_iter()
        .filter_map(|key| value.get(key).and_then(serde_json::Value::as_bool));
    let exits = ["exit_code", "exitCode"]
        .into_iter()
        .filter_map(|key| value.get(key).and_then(serde_json::Value::as_i64))
        .map(|code| code != 0);
    let known: Vec<_> = flags.chain(exits).collect();
    if !known.is_empty() {
        return Some(Some(known.into_iter().any(|failed| failed)));
    }
    match value.get("status").and_then(serde_json::Value::as_str) {
        Some("fulfilled") if value.get("value").is_some() => {
            Some(value.get("value").and_then(structured_tool_failure))
        }
        Some("rejected") if value.get("reason").is_some() => Some(Some(true)),
        _ if value.get("chunk_id").is_some() && value.get("session_id").is_some() => Some(None),
        _ if ["is_error", "isError", "exit_code", "exitCode"]
            .iter()
            .any(|key| value.get(key).is_some()) =>
        {
            Some(None)
        }
        _ => None,
    }
}

fn codex_tool_failure(payload: &serde_json::Value) -> Option<bool> {
    if let Some(failed) = structured_tool_failure(payload) {
        return Some(failed);
    }
    let output = payload.get("output")?;
    fn text_outcome(text: &str) -> Option<Option<bool>> {
        // Codex wraps native exec/MCP results in exact JSON text blocks. Parsing
        // the whole block preserves that metadata without interpreting output prose.
        serde_json::from_str(text)
            .ok()
            .as_ref()
            .and_then(structured_tool_outcome)
    }
    if let Some(text) = output.as_str() {
        return text_outcome(text).flatten();
    }
    if let Some(parts) = output.as_array() {
        let outcomes: Vec<_> = parts
            .iter()
            .filter_map(|part| {
                if part.get("type").and_then(serde_json::Value::as_str) == Some("text") {
                    part.get("text")
                        .and_then(serde_json::Value::as_str)
                        .and_then(text_outcome)
                } else {
                    None
                }
            })
            .collect();
        if outcomes.contains(&Some(true)) {
            return Some(true);
        }
        return (!outcomes.is_empty() && outcomes.iter().all(|result| *result == Some(false)))
            .then_some(false);
    }
    structured_tool_failure(output)
}

fn push_tool_message(
    messages: &mut Vec<AgentMessage>,
    text: String,
    timestamp: &Option<String>,
    call_id: Option<&serde_json::Value>,
    name: Option<&str>,
    phase: &str,
    failed: Option<bool>,
) {
    let before = messages.len();
    if text.trim().is_empty() && failed.is_some() {
        messages.push(AgentMessage {
            role: "tool".into(),
            text,
            timestamp: timestamp.clone(),
            tool_call_id: None,
            tool_name: None,
            tool_phase: None,
            tool_failed: failed,
            assistant_phase: None,
        });
    } else {
        push_message(messages, "tool", text, timestamp);
    }
    if messages.len() > before {
        let message = messages.last_mut().unwrap();
        message.tool_call_id = call_id
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        message.tool_name = name.map(str::to_string);
        message.tool_phase = Some(phase.into());
        message.tool_failed = failed;
    }
}

fn push_message(
    messages: &mut Vec<AgentMessage>,
    role: &str,
    text: String,
    timestamp: &Option<String>,
) {
    let trimmed = text.trim_start();
    let context = [
        "<environment_context>",
        "<system-reminder>",
        "<skills_instructions>",
        "<permissions instructions>",
        "<INSTRUCTIONS>",
    ];
    if trimmed.is_empty() || context.iter().any(|tag| trimmed.starts_with(tag)) {
        return;
    }
    messages.push(AgentMessage {
        role: role.into(),
        text,
        timestamp: timestamp.clone(),
        tool_call_id: None,
        tool_name: None,
        tool_phase: None,
        tool_failed: None,
        assistant_phase: None,
    });
}

/// Both Agents use text/image arrays. Unknown structured parts are omitted:
/// recursively flattening arbitrary fields could disclose private reasoning.
fn flatten_content(content: Option<&serde_json::Value>) -> String {
    match content {
        Some(serde_json::Value::String(text)) => text.clone(),
        Some(serde_json::Value::Array(parts)) => parts
            .iter()
            .map(flatten_part)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn flatten_part(part: &serde_json::Value) -> String {
    let kind = part
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    match kind {
        "text" | "input_text" | "output_text" | "summary_text" => part
            .get("text")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .into(),
        "image" | "input_image" | "image_url" | "output_image" => {
            let source = part
                .get("image_url")
                .and_then(|url| {
                    url.as_str()
                        .or_else(|| url.get("url").and_then(serde_json::Value::as_str))
                })
                .or_else(|| part.get("url").and_then(serde_json::Value::as_str));
            let address = source.map(str::to_string).or_else(|| {
                let source = part.get("source")?;
                match source.get("type")?.as_str()? {
                    "url" => source.get("url")?.as_str().map(str::to_string),
                    "base64" => {
                        let mime = source.get("media_type")?.as_str()?;
                        let data = source.get("data")?.as_str()?;
                        Some(format!("data:{mime};base64,{data}"))
                    }
                    _ => None,
                }
            });
            match address {
                Some(address) => image_markdown(&address).unwrap_or_else(|| {
                    if address.len() > 700_000 {
                        "[图片无法显示：内嵌图片过大，请在 Mac 查看]".into()
                    } else {
                        "[图片无法显示：图片来源或格式暂不支持，请在 Mac 查看]".into()
                    }
                }),
                None => "[图片无法显示：缺少可用图片内容，请在 Mac 查看]".into(),
            }
        }
        _ => String::new(),
    }
}

fn image_markdown(address: &str) -> Option<String> {
    // The UI deliberately requires a tap before fetching remote images.
    // No file paths or arbitrary data MIME types cross this presentation path.
    if address.chars().any(char::is_control) || address.len() > 700_000 {
        return None;
    }
    let remote = address.starts_with("https://") || address.starts_with("http://");
    let data_image = [
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "image/avif",
    ]
    .iter()
    .any(|mime| address.starts_with(&format!("data:{mime};base64,")));
    if !remote && !data_image {
        return None;
    }
    let escaped = address
        .replace('(', "%28")
        .replace(')', "%29")
        .replace('<', "%3C")
        .replace('>', "%3E")
        .replace(' ', "%20");
    Some(format!("![图片]({escaped})"))
}

fn tool_text(name: &str, input: &serde_json::Value) -> String {
    let body = input
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| serde_json::to_string_pretty(input).unwrap_or_default());
    // Use a fence longer than every run in the actual output.
    let longest = body.split(|c| c != '`').map(str::len).max().unwrap_or(0);
    let fence = "`".repeat(longest.max(2) + 1);
    format!("{name}\n\n{fence}text\n{body}\n{fence}")
}

fn collect_files(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_files(&path, out);
        } else {
            out.push(path);
        }
    }
}

/// Claude Code keeps one directory per project under `~/.claude/projects/`;
/// every session transcript inside it is a `.jsonl` file whose first line
/// carries the real `cwd` the session ran in. `last_seen` is the newest
/// transcript file's modification time — the closest thing available to
/// "when was this project last used" without parsing every line.
fn claude_projects(base: &Path) -> Vec<AgentProject> {
    let Ok(entries) = std::fs::read_dir(base.join(".claude/projects")) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| first_session_cwd(&entry.path()))
        .collect()
}

fn first_session_cwd(project_dir: &Path) -> Option<AgentProject> {
    let entries = std::fs::read_dir(project_dir).ok()?;
    let mut newest_mtime: Option<String> = None;
    let mut cwd: Option<String> = None;
    let mut threads = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(std::ffi::OsStr::to_str) != Some("jsonl") {
            continue;
        }
        let modified = modified_rfc3339(&path);
        if let Some(modified) = &modified {
            if newest_mtime
                .as_ref()
                .is_none_or(|current| modified > current)
            {
                newest_mtime = Some(modified.clone());
            }
        }
        if let Some(id) = path.file_stem().and_then(|stem| stem.to_str()) {
            threads.push(AgentThread {
                id: id.to_string(),
                title: "对话".into(),
                updated_at: modified,
                source: Some("cli".into()),
            });
        }
        if cwd.is_none() {
            let file = std::fs::File::open(&path).ok()?;
            let mut line = String::new();
            if std::io::BufReader::new(file).read_line(&mut line).ok()? > 0 {
                let value: serde_json::Value = serde_json::from_str(&line).ok()?;
                cwd = value
                    .get("cwd")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_string);
            }
        }
    }
    threads.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    Some(AgentProject {
        path: cwd?,
        last_seen: newest_mtime,
        name: None,
        threads,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn model_catalog_returns_only_bounded_labels_and_ids() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".codex")).unwrap();
        fs::write(dir.path().join(".codex/models_cache.json"), r#"{"models":[
            {"slug":"visible","display_name":"Visible","visibility":"list","base_instructions":"PRIVATE"},
            {"slug":"hidden","visibility":"hide"},{"slug":"visible"},{"slug":"fallback"}
        ]}"#).unwrap();
        let models = list_agent_models("codex", dir.path());
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].name, "Visible");
        assert_eq!(models[1].name, "fallback");
        assert!(!serde_json::to_string(&models).unwrap().contains("PRIVATE"));
        assert!(list_agent_models("claude", dir.path()).is_empty());
    }

    fn catalog_database(base: &Path, version: u32) -> rusqlite::Connection {
        fs::create_dir_all(base.join(".codex")).unwrap();
        let db = rusqlite::Connection::open(base.join(format!(".codex/state_{version}.sqlite")))
            .unwrap();
        db.execute_batch("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL, updated_at INTEGER NOT NULL, source TEXT NOT NULL, archived INTEGER NOT NULL);").unwrap();
        db
    }

    fn catalog_row(db: &rusqlite::Connection, id: &str, cwd: &str, source: &str, archived: bool) {
        db.execute(
            "INSERT INTO threads VALUES (?1, ?2, ?3, 1793493600, ?4, ?5)",
            rusqlite::params![id, cwd, format!("Title {id}"), source, archived],
        )
        .unwrap();
    }

    #[test]
    fn native_projects_replace_legacy_registrations_and_do_not_resurrect_removed_roots() {
        let dir = tempfile::tempdir().unwrap();
        let db = catalog_database(dir.path(), 5);
        db.execute_batch("CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT, updated_at_ms INTEGER, position INTEGER);
            CREATE TABLE project_roots(project_id TEXT, path TEXT, position INTEGER);
            ALTER TABLE threads ADD COLUMN project_id TEXT;
            INSERT INTO projects VALUES('current','Current name',1793493600000,0);
            INSERT INTO project_roots VALUES('current','/repo',0);").unwrap();
        // Explicit column lists because the native fixture has project_id too.
        for (id, cwd, project_id) in [
            ("kept", "/elsewhere", Some("current")),
            ("removed", "/old", Some("deleted")),
            ("cli", "/repo/sub", None),
            ("dangling", "/repo", Some("deleted")),
        ] {
            db.execute("INSERT INTO threads(id,cwd,title,updated_at,source,archived,project_id) VALUES(?1,?2,?1,1793493600,'cli',0,?3)", rusqlite::params![id,cwd,project_id]).unwrap();
        }
        fs::write(dir.path().join(".codex/.codex-global-state.json"), r#"{"local-projects":{"old":{"name":"Removed","rootPaths":["/old"]}},"thread-project-assignments":{"kept":{"projectId":"old"}}}"#).unwrap();
        let projects = list_agent_projects("codex", dir.path());
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name.as_deref(), Some("Current name"));
        assert_eq!(
            projects[0]
                .threads
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>(),
            vec!["cli", "kept"]
        );
        db.execute("DELETE FROM project_roots", []).unwrap();
        db.execute("DELETE FROM projects", []).unwrap();
        assert!(list_agent_projects("codex", dir.path()).is_empty());
    }

    #[test]
    fn codex_database_lists_cli_without_desktop_state_and_uses_newest_numeric_schema() {
        let dir = tempfile::tempdir().unwrap();
        let old = catalog_database(dir.path(), 9);
        catalog_row(&old, "obsolete", "/old", "cli", false);
        let current = catalog_database(dir.path(), 10);
        catalog_row(&current, "cli", "/repo", "cli", false);
        catalog_row(&current, "desktop", "/repo", "vscode", false);
        catalog_row(&current, "exec", "/repo", "exec", false);
        catalog_row(&current, "future", "/other", "future-client", false);
        fs::write(
            dir.path().join(".codex/session_index.jsonl"),
            r#"{"id":"cli","thread_name":"Renamed CLI"}"#,
        )
        .unwrap();
        let projects = list_agent_projects("codex", dir.path());
        assert_eq!(projects.len(), 2);
        let repo = projects.iter().find(|p| p.path == "/repo").unwrap();
        assert_eq!(repo.threads.len(), 3);
        assert_eq!(repo.threads[2].source.as_deref(), Some("cli"));
        assert_eq!(repo.threads[0].source.as_deref(), Some("cli"));
        assert_eq!(repo.threads[1].source.as_deref(), Some("desktop"));
        assert_eq!(repo.threads[0].title, "Renamed CLI");
        assert!(repo.threads[0]
            .updated_at
            .as_deref()
            .unwrap()
            .starts_with("2026-11-01T"));
        assert_eq!(projects[0].threads[0].source.as_deref(), Some("unknown"));
    }

    #[test]
    fn codex_assignments_win_all_roots_match_and_archived_subagents_do_not_leak() {
        let dir = tempfile::tempdir().unwrap();
        let db = catalog_database(dir.path(), 5);
        catalog_row(&db, "assigned", "/repo/nested", "cli", false);
        catalog_row(&db, "second-root", "/second/sub", "vscode", false);
        catalog_row(&db, "nested", "/repo/nested/sub", "cli", false);
        catalog_row(&db, "boundary", "/repository", "cli", false);
        catalog_row(&db, "archived", "/repo", "cli", true);
        catalog_row(
            &db,
            "worker",
            "/repo",
            r#"{"subagent":{"thread_spawn":{}}}"#,
            false,
        );
        fs::write(
            dir.path().join(".codex/.codex-global-state.json"),
            r#"{
            "local-projects": {
                "main": {"name":"Main", "rootPaths":["/repo", "/second"]},
                "nested": {"name":"Nested", "rootPaths":["/repo/nested"]},
                "other": {"name":"Other", "rootPaths":["/other"]}
            },
            "thread-project-assignments": {
                "assigned":{"projectId":"other"},
                "archived":{"projectId":"main"},
                "worker":{"projectId":"main"},
                "deleted":{"projectId":"main"}
            }
        }"#,
        )
        .unwrap();
        let projects = list_agent_projects("codex", dir.path());
        let ids = |path: &str| {
            projects
                .iter()
                .find(|p| p.path == path)
                .unwrap()
                .threads
                .iter()
                .map(|t| t.id.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(ids("/other"), ["assigned"]);
        assert_eq!(ids("/repo"), ["second-root"]);
        assert_eq!(ids("/repo/nested"), ["nested"]);
        assert_eq!(ids("/repository"), ["boundary"]);
        assert_eq!(projects.iter().map(|p| p.threads.len()).sum::<usize>(), 4);
    }

    #[test]
    fn codex_same_root_projects_merge_threads_instead_of_dropping_one() {
        let dir = tempfile::tempdir().unwrap();
        let db = catalog_database(dir.path(), 5);
        catalog_row(&db, "a", "/repo", "cli", false);
        catalog_row(&db, "b", "/repo", "vscode", false);
        fs::write(
            dir.path().join(".codex/.codex-global-state.json"),
            r#"{
            "local-projects": {"a":{"rootPaths":["/repo"]},"b":{"rootPaths":["/repo"]}},
            "thread-project-assignments": {"a":{"projectId":"a"},"b":{"projectId":"b"}}
        }"#,
        )
        .unwrap();
        let projects = list_agent_projects("codex", dir.path());
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].threads.len(), 2);
    }

    /// A rename that leaves the old registration behind creates two project
    /// ids sharing one directory. The merged project must show the name of
    /// whichever registration actually saw the more recent activity, not
    /// whichever id happens to sort first.
    #[test]
    fn codex_same_root_duplicate_project_prefers_name_of_the_more_recently_active_registration() {
        let dir = tempfile::tempdir().unwrap();
        let db = catalog_database(dir.path(), 5);
        catalog_row(&db, "old-thread", "/repo", "cli", false);
        catalog_row(&db, "new-thread", "/repo", "cli", false);
        db.execute(
            "UPDATE threads SET updated_at = 1793493600 + 1000 WHERE id = 'new-thread'",
            [],
        )
        .unwrap();
        fs::write(
            dir.path().join(".codex/.codex-global-state.json"),
            r#"{
            "local-projects": {"a":{"name":"Old Name","rootPaths":["/repo"]},"b":{"name":"New Name","rootPaths":["/repo"]}},
            "thread-project-assignments": {"old-thread":{"projectId":"a"},"new-thread":{"projectId":"b"}}
        }"#,
        )
        .unwrap();
        let projects = list_agent_projects("codex", dir.path());
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name.as_deref(), Some("New Name"));
        assert_eq!(projects[0].threads.len(), 2);
    }

    #[test]
    fn codex_thread_messages_reads_user_and_assistant_turns() {
        let dir = tempfile::tempdir().unwrap();
        let session_dir = dir.path().join(".codex/sessions/2026/03/01");
        fs::create_dir_all(&session_dir).unwrap();
        let lines = [
            r#"{"type":"session_meta","payload":{"cwd":"/x"}}"#,
            r#"{"type":"response_item","timestamp":"2026-03-01T12:04:41Z","payload":{"role":"developer","content":"<skills_instructions>…"}}"#,
            r#"{"type":"response_item","timestamp":"2026-03-01T12:04:42Z","payload":{"role":"user","content":"<environment_context>cwd</environment_context>"}}"#,
            r#"{"type":"response_item","timestamp":"2026-03-01T12:04:43Z","payload":{"role":"user","content":[{"type":"input_text","text":"修一下登录页"}]}}"#,
            r#"{"type":"response_item","timestamp":"2026-03-01T12:04:44Z","payload":{"role":"custom_tool_call","content":""}}"#,
            r#"{"type":"response_item","timestamp":"2026-03-01T12:05:01Z","payload":{"role":"assistant","content":[{"type":"output_text","text":"已修复"}]}}"#,
        ];
        let compressed = zstd::encode_all(lines.join("\n").as_bytes(), 3).unwrap();
        fs::write(session_dir.join("rollout-x-01a08175.jsonl.zst"), compressed).unwrap();
        let messages = list_thread_messages("codex", "01a08175", dir.path());
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[0].text, "修一下登录页");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].text, "已修复");
    }

    #[test]
    fn claude_thread_messages_reads_turns_and_skips_tooling() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join(".claude/projects/-x");
        fs::create_dir_all(&project).unwrap();
        let lines = [
            r#"{"type":"user","timestamp":"2026-03-01T10:00:00Z","message":{"content":"帮我看下这个报错"}}"#,
            r#"{"type":"summary","summary":"old"}"#,
            r#"{"type":"assistant","timestamp":"2026-03-01T10:00:30Z","message":{"content":[{"type":"text","text":"这个报错是因为…"}]}}"#,
        ];
        fs::write(project.join("abc-123.jsonl"), lines.join("\n")).unwrap();
        let messages = list_thread_messages("claude", "abc-123", dir.path());
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text, "帮我看下这个报错");
        assert_eq!(messages[1].text, "这个报错是因为…");
    }

    #[test]
    fn assistant_phase_uses_explicit_metadata_and_keeps_legacy_text() {
        use serde_json::json;
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        fs::create_dir_all(&sessions).unwrap();
        let records = [
            json!({"type":"message","role":"assistant","phase":"commentary","content":"progress"}),
            json!({"type":"message","role":"assistant","channel":"final","content":"result"}),
            json!({"type":"message","role":"assistant","phase":"final_answer","content":"result two"}),
            json!({"type":"message","role":"assistant","content":"I will inspect it"}),
            json!({"type":"message","role":"assistant","phase":"future","content":"unchanged"}),
            json!({"type":"message","role":"user","phase":"commentary","content":"user"}),
        ];
        fs::write(
            sessions.join("rollout-phase.jsonl"),
            records
                .into_iter()
                .map(|payload| json!({"type":"response_item","payload":payload}).to_string())
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .unwrap();
        let messages = list_thread_messages("codex", "phase", dir.path());
        assert_eq!(
            messages
                .iter()
                .map(|message| message.assistant_phase.as_deref())
                .collect::<Vec<_>>(),
            [
                Some("commentary"),
                Some("final_answer"),
                Some("final_answer"),
                None,
                None,
                None
            ]
        );
        assert_eq!(messages[3].text, "I will inspect it");
        assert_eq!(messages[4].text, "unchanged");
        assert_eq!(assistant_phase(&json!({"phase":"analysis"})), None);
        assert_eq!(
            assistant_phase(&json!({"phase":"commentary","channel":"final"})).as_deref(),
            Some("commentary")
        );
        let old: AgentMessage =
            serde_json::from_str(r#"{"role":"assistant","text":"legacy","timestamp":null}"#)
                .unwrap();
        assert!(old.assistant_phase.is_none());
    }

    #[test]
    fn tool_failures_use_structured_results_not_output_prose() {
        use serde_json::json;
        let blocks = |values: Vec<serde_json::Value>| {
            json!({"output": values.into_iter().map(|value|
            json!({"type":"text", "text":value.to_string()})).collect::<Vec<_>>()})
        };
        assert_eq!(
            codex_tool_failure(&json!({"output":"error: this is prose"})),
            None
        );
        assert_eq!(
            codex_tool_failure(&json!({"output":"{\"message\":\"failed\"}"})),
            None
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"exit_code":0,"output":"error: example text"})
            ])),
            Some(false)
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![json!({"exit_code":1,"output":""})])),
            Some(true)
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![json!({"isError":true,"content":[]})])),
            Some(true)
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"status":"fulfilled","value":{"exit_code":2,"output":""}})
            ])),
            Some(true)
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"status":"rejected","reason":"failed request"})
            ])),
            Some(true)
        );
        // Never recursively decode program-produced output that looks like metadata.
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"exit_code":0,"output":"{\"exit_code\":1}"})
            ])),
            Some(false)
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![json!({"chunk_id":"a","session_id":123})])),
            None
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"exit_code":0}),
                json!({"chunk_id":"a","session_id":123})
            ])),
            None
        );
        assert_eq!(
            codex_tool_failure(&blocks(vec![
                json!({"exit_code":1}),
                json!({"chunk_id":"a","session_id":123})
            ])),
            Some(true)
        );
        assert_eq!(
            codex_tool_failure(&json!({"output":[{"type":"text","text":"Script completed"},
            {"type":"text","text":"{\"exit_code\":0,\"output\":\"\"}"}]})),
            Some(false)
        );
        assert_eq!(
            structured_tool_failure(&json!({"status":"completed"})),
            None
        );
        assert_eq!(structured_tool_failure(&json!({"exit_code":"1"})), None);
        assert_eq!(structured_tool_failure(&json!({"stderr":"warning"})), None);
    }

    #[test]
    fn empty_failed_results_survive_history_projection_and_old_rows_decode() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        let project = dir.path().join(".claude/projects/test");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&project).unwrap();
        fs::write(sessions.join("rollout-empty-failed.jsonl"), serde_json::json!({"type":"response_item",
            "payload":{"type":"function_call_output","call_id":"c1","output":{"isError":true,"content":[]}}}).to_string()).unwrap();
        fs::write(project.join("empty-failed.jsonl"), serde_json::json!({"type":"user","message":{"content":[
            {"type":"tool_result","tool_use_id":"c2","is_error":true,"content":""},
            {"type":"tool_result","tool_use_id":"c3","is_error":false,"content":"warning: error example"},
            {"type":"tool_result","tool_use_id":"c4","content":"failed in example documentation"}
        ]}}).to_string()).unwrap();
        let codex = list_thread_messages("codex", "empty-failed", dir.path());
        assert_eq!(codex.len(), 1);
        assert_eq!(codex[0].tool_failed, Some(true));
        assert_eq!(codex[0].tool_call_id.as_deref(), Some("c1"));
        assert!(codex[0].text.is_empty());
        let claude = list_thread_messages("claude", "empty-failed", dir.path());
        assert_eq!(
            claude.iter().map(|row| row.tool_failed).collect::<Vec<_>>(),
            vec![Some(true), Some(false), None]
        );
        assert_eq!(claude[0].tool_call_id.as_deref(), Some("c2"));
        assert_eq!(claude[0].tool_phase.as_deref(), Some("output"));
        assert!(claude[0].text.is_empty());
        let old: AgentMessage =
            serde_json::from_str(r#"{"role":"tool","text":"old","timestamp":null}"#).unwrap();
        assert_eq!(old.tool_failed, None);
    }

    #[test]
    fn codex_rich_history_keeps_images_public_summary_and_tool_records() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        fs::create_dir_all(&sessions).unwrap();
        let lines = [
            serde_json::json!({"type":"response_item", "payload":{"type":"message","role":"user","content":[
                {"type":"input_text","text":"<div>please fix this screenshot</div>"},
                {"type":"input_image","image_url":"https://example.com/image(1).png"}
            ]}}),
            serde_json::json!({"type":"response_item", "payload":{"type":"reasoning","summary":[
                {"type":"summary_text","text":"Check layout and contrast."}
            ], "content":[{"type":"reasoning_text","text":"PRIVATE"}],"encrypted_content":"SECRET"}}),
            serde_json::json!({"type":"response_item", "payload":{"type":"function_call","call_id":"read-1","name":"read_file","arguments":"{\"path\":\"app.tsx\"}"}}),
            serde_json::json!({"type":"response_item", "payload":{"type":"function_call_output","call_id":"read-1","output":"file contents"}}),
            serde_json::json!({"type":"response_item", "payload":{"type":"message","role":"assistant","content":[
                {"type":"output_text","text":"## Fixed"}
            ]}}),
        ];
        let text = lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(sessions.join("rollout-rich-thread.jsonl"), text).unwrap();
        let messages = list_thread_messages("codex", "rich-thread", dir.path());
        assert_eq!(
            messages.iter().map(|m| m.role.as_str()).collect::<Vec<_>>(),
            ["user", "summary", "tool", "tool", "assistant"]
        );
        assert!(messages[0].text.starts_with("<div>"));
        assert!(messages[0]
            .text
            .contains("![图片](https://example.com/image%281%29.png)"));
        assert_eq!(messages[1].text, "Check layout and contrast.");
        assert!(messages[2].text.contains("read_file"));
        assert_eq!(messages[3].text, "file contents");
        assert_eq!(messages[2].tool_call_id.as_deref(), Some("read-1"));
        assert_eq!(messages[2].tool_name.as_deref(), Some("read_file"));
        assert_eq!(messages[2].tool_phase.as_deref(), Some("input"));
        assert_eq!(messages[3].tool_call_id, messages[2].tool_call_id);
        assert_eq!(messages[3].tool_phase.as_deref(), Some("output"));
        assert!(messages
            .iter()
            .all(|m| !m.text.contains("PRIVATE") && !m.text.contains("SECRET")));
    }

    #[test]
    fn claude_rich_history_preserves_images_and_tool_order_without_private_thinking() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join(".claude/projects/test");
        fs::create_dir_all(&project).unwrap();
        let records = [
            serde_json::json!({"type":"user","message":{"content":[
                {"type":"text","text":"See screenshot"},
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGVsbG8="}}
            ]}}),
            serde_json::json!({"type":"assistant","message":{"content":[
                {"type":"thinking","thinking":"PRIVATE","text":"PRIVATE TOO"},
                {"type":"text","text":"Opening file"},
                {"type":"tool_use","id":"read-2","name":"Read","input":{"file_path":"src/main.ts"}},
                {"type":"text","text":"Finished reading"}
            ]}}),
            serde_json::json!({"type":"user","message":{"content":[
                {"type":"tool_result","tool_use_id":"read-2","content":[{"type":"text","text":"file output"}]}
            ]}}),
        ];
        fs::write(
            project.join("rich.jsonl"),
            records
                .iter()
                .map(serde_json::Value::to_string)
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .unwrap();
        let messages = list_thread_messages("claude", "rich", dir.path());
        assert_eq!(
            messages.iter().map(|m| m.role.as_str()).collect::<Vec<_>>(),
            ["user", "assistant", "tool", "assistant", "tool"]
        );
        assert!(messages[0]
            .text
            .contains("![图片](data:image/png;base64,aGVsbG8=)"));
        assert_eq!(messages[2].tool_call_id.as_deref(), Some("read-2"));
        assert_eq!(messages[2].tool_phase.as_deref(), Some("input"));
        assert_eq!(messages[4].tool_call_id, messages[2].tool_call_id);
        assert_eq!(messages[4].tool_phase.as_deref(), Some("output"));
        assert_eq!(messages[1].text, "Opening file");
        assert_eq!(messages[3].text, "Finished reading");
        assert_eq!(messages[4].text, "file output");
        assert!(messages.iter().all(|m| !m.text.contains("PRIVATE")));
    }

    #[test]
    fn unsupported_image_schemes_and_unknown_parts_are_not_flattened() {
        for source in [
            "file:///private/secret.png",
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "https://example.com/a\nb",
        ] {
            assert!(image_markdown(source).is_none());
        }
        assert_eq!(
            flatten_content(Some(&serde_json::json!([
                {"type":"thinking", "text":"hidden"},
                {"type":"image", "source":{"type":"url","url":"https://example.com/a.png"}},
                {"type":"image_url", "image_url":{"url":"https://example.com/b.png"}}
            ]))),
            "![图片](https://example.com/a.png)\n![图片](https://example.com/b.png)"
        );
    }

    #[test]
    fn unsupported_image_only_messages_keep_placeholder_without_exposing_source() {
        let cases = [
            serde_json::json!({"type":"image_url", "image_url":"file:///private/secret.png"}),
            serde_json::json!({"type":"input_image", "image_url": format!("data:image/png;base64,{}", "a".repeat(700_000))}),
            serde_json::json!({"type":"image", "source":{"type":"unavailable", "path":"/private/secret.png"}}),
        ];
        for part in cases {
            let text = flatten_content(Some(&serde_json::json!([part])));
            assert!(text.starts_with("[图片无法显示："));
            assert!(text.contains("请在 Mac 查看"));
            assert!(!text.contains("/private/") && !text.contains("base64"));
            let mut messages = Vec::new();
            push_message(&mut messages, "user", text, &None);
            assert_eq!(messages.len(), 1, "An image-only turn must remain visible");
        }
    }

    #[test]
    fn multiple_embedded_images_fit_one_control_response_with_visible_notice() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join(".codex/sessions");
        fs::create_dir_all(&sessions).unwrap();
        let image = format!("data:image/png;base64,{}", "a".repeat(600_000));
        let records = [
            serde_json::json!({"type":"response_item", "payload":{"role":"user","content":[{"type":"input_image","image_url":image}]}}),
            serde_json::json!({"type":"response_item", "payload":{"role":"user","content":[{"type":"input_image","image_url":image}]}}),
            serde_json::json!({"type":"response_item", "payload":{"role":"assistant","content":"Latest reply"}}),
        ];
        fs::write(
            sessions.join("rollout-size-budget.jsonl"),
            records
                .iter()
                .map(serde_json::Value::to_string)
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .unwrap();
        let messages = list_thread_messages("codex", "size-budget", dir.path());
        assert!(serde_json::to_vec(&messages).unwrap().len() < HISTORY_JSON_BUDGET);
        assert!(messages[0].text.contains("仅显示部分记录"));
        assert_eq!(messages.last().unwrap().text, "Latest reply");
        assert_eq!(messages.len(), 4, "Image-only turns should remain visible");
        assert!(messages[1].text.contains("图片请在 Mac 查看"));
        assert!(messages[2].text.contains("图片请在 Mac 查看"));
    }

    #[test]
    fn huge_unicode_and_escaped_tool_text_is_bounded_and_recent_turns_are_retained() {
        let mut messages: Vec<_> = (0..8)
            .map(|index| AgentMessage {
                role: "tool".into(),
                text: format!("tool-{index} {}", "工具🙂\n\u{00}\"".repeat(100_000)),
                timestamp: None,
                tool_call_id: None,
                tool_name: None,
                tool_phase: None,
                tool_failed: None,
                assistant_phase: None,
            })
            .collect();
        messages.push(AgentMessage {
            role: "assistant".into(),
            text: "最新回复🙂".into(),
            timestamp: None,
            tool_call_id: None,
            tool_name: None,
            tool_phase: None,
            tool_failed: None,
            assistant_phase: None,
        });
        let messages = bounded_history(messages);
        assert!(serde_json::to_vec(&messages).unwrap().len() < HISTORY_JSON_BUDGET);
        assert!(messages.first().unwrap().text.contains("仅显示部分记录"));
        assert_eq!(messages.last().unwrap().text, "最新回复🙂");
        assert!(messages
            .iter()
            .any(|message| message.text.contains("内容已截短")));
        assert!(messages
            .iter()
            .any(|message| message.text.starts_with("tool-7")));
        assert!(!messages
            .iter()
            .any(|message| message.text.starts_with("tool-0")));
    }

    #[test]
    fn unknown_agent_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        assert!(list_agent_projects("herdr", dir.path()).is_empty());
    }

    #[test]
    fn missing_files_return_empty_not_error() {
        let dir = tempfile::tempdir().unwrap();
        assert!(list_agent_projects("codex", dir.path()).is_empty());
        assert!(list_agent_projects("claude", dir.path()).is_empty());
    }

    #[test]
    fn codex_reads_desktop_projects_not_sessions() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join(".codex")).unwrap();
        // Trusted directories and session files must not show up as projects.
        fs::write(
            dir.path().join(".codex/config.toml"),
            "[projects.\"/Users/mac/rjgf/aiops\"]\ntrust_level = \"trusted\"\n",
        )
        .unwrap();
        fs::write(
            dir.path().join(".codex/.codex-global-state.json"),
            r#"{"local-projects":{
                "p1":{"id":"p1","name":"湾区智谷","rootPaths":["/Users/mac/rjgf/bay-area-ai"],"createdAt":1791796862557,"updatedAt":1791796862557},
                "p2":{"id":"p2","name":"","rootPaths":[],"createdAt":1,"updatedAt":1}
            },"thread-project-assignments":{
                "thread-1":{"projectKind":"local","projectId":"p1"}
            }}"#,
        )
        .unwrap();
        fs::write(
            dir.path().join(".codex/session_index.jsonl"),
            "{\"id\":\"thread-1\",\"thread_name\":\"修登录\",\"updated_at\":\"2026-10-12T09:21:02.557Z\"}\n",
        )
        .unwrap();
        let projects = list_agent_projects("codex", dir.path());
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].path, "/Users/mac/rjgf/bay-area-ai");
        assert_eq!(projects[0].name.as_deref(), Some("湾区智谷"));
        assert!(projects[0].last_seen.is_some());
        assert_eq!(projects[0].threads.len(), 1);
        assert_eq!(projects[0].threads[0].title, "修登录");
        assert_eq!(projects[0].threads[0].source.as_deref(), Some("unknown"));
    }

    #[test]
    fn claude_reads_cwd_and_newest_mtime_from_session_files() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join(".claude/projects/-Users-mac-mac-dev");
        fs::create_dir_all(&project).unwrap();
        let session = project.join("session.jsonl");
        fs::write(
            &session,
            "{\"cwd\":\"/Users/mac/mac-dev\",\"other\":1}\n{\"ignored\":true}\n",
        )
        .unwrap();
        let projects = list_agent_projects("claude", dir.path());
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].path, "/Users/mac/mac-dev");
        assert_eq!(projects[0].threads[0].source.as_deref(), Some("cli"));
        assert!(
            projects[0].last_seen.is_some(),
            "session file mtime should be reported"
        );
    }

    #[test]
    fn claude_skips_project_dir_with_no_jsonl() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join(".claude/projects/-Users-mac-empty");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("notes.txt"), "not a session").unwrap();
        assert!(list_agent_projects("claude", dir.path()).is_empty());
    }
}
