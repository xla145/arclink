use crate::runtime::native_error;
use agentd::Result;
use serde::Serialize;
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
};
use tauri::{AppHandle, Manager};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;

const BUDGET: usize = 256 * 1024;
#[derive(Serialize)]
pub struct RecentLogs {
    text: String,
    truncated: bool,
}
fn read_logs(directory: &Path) -> Result<RecentLogs> {
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(RecentLogs {
                text: String::new(),
                truncated: false,
            })
        }
        Err(_) => return Err(native_error("无法读取日志目录，请检查目录权限后重试。")),
    };
    let mut files = Vec::new();
    let mut truncated = false;
    for (index, entry) in entries.enumerate() {
        if index >= 64 {
            truncated = true;
            break;
        }
        let entry = entry.map_err(|_| native_error("无法读取日志文件列表。"))?;
        let kind = match entry.file_type() {
            Ok(kind) => kind,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(native_error("无法读取日志文件信息。")),
        };
        if !kind.is_file() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !(name.ends_with(".log") || name.contains(".log.")) {
            continue;
        }
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(native_error("无法读取日志文件信息。")),
        };
        files.push((metadata.modified().ok(), entry.path()));
    }
    files.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    let mut remaining = BUDGET;
    let mut chunks = Vec::new();
    for (_, path) in files {
        if remaining == 0 {
            truncated = true;
            break;
        }
        // Open without following a swapped symlink on Unix.
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = match options.open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(native_error("无法读取日志文件，请检查文件权限后重试。")),
        };
        if !file
            .metadata()
            .map_err(|_| native_error("无法读取日志文件信息。"))?
            .is_file()
        {
            continue;
        }
        let length = file
            .metadata()
            .map_err(|_| native_error("无法读取日志文件大小。"))?
            .len();
        let start = length.saturating_sub(remaining as u64);
        truncated |= start > 0;
        file.seek(SeekFrom::Start(start))
            .map_err(|_| native_error("无法读取最近日志。"))?;
        let mut bytes = Vec::new();
        file.take(remaining as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| native_error("读取日志失败，请刷新重试。"))?;
        // Lossy decoding may expand invalid UTF-8; bound the returned text too.
        let decoded = String::from_utf8_lossy(&bytes);
        let mut text = decoded.into_owned();
        if text.len() > remaining {
            let mut end = remaining;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            text.truncate(end);
            truncated = true;
        }
        remaining -= text.len();
        chunks.push(text);
    }
    chunks.reverse();
    Ok(RecentLogs {
        text: chunks.concat(),
        truncated,
    })
}
fn directory(app: &AppHandle) -> Result<std::path::PathBuf> {
    app.path()
        .app_log_dir()
        .map_err(|_| native_error("无法定位日志目录。"))
}
#[tauri::command]
pub async fn get_recent_logs(app: AppHandle) -> Result<RecentLogs> {
    let directory = directory(&app)?;
    tauri::async_runtime::spawn_blocking(move || read_logs(&directory))
        .await
        .map_err(|_| native_error("读取日志任务失败。"))?
}
#[tauri::command]
pub async fn copy_recent_logs(app: AppHandle) -> Result<()> {
    let logs = get_recent_logs(app.clone()).await?;
    app.clipboard()
        .write_text(logs.text)
        .map_err(|_| native_error("无法复制日志，请重试或导出文件。"))
}
#[tauri::command]
pub async fn export_recent_logs(app: AppHandle) -> Result<bool> {
    let logs = get_recent_logs(app.clone()).await?;
    tauri::async_runtime::spawn_blocking(move || {
        let selected = app
            .dialog()
            .file()
            .set_title("导出最近日志")
            .set_file_name("ArcLink-diagnostics.log")
            .add_filter("日志", &["log"])
            .blocking_save_file();
        let Some(selected) = selected else {
            return Ok(false);
        };
        let path = selected
            .into_path()
            .map_err(|_| native_error("请选择本机文件位置。"))?;
        let mut file =
            File::create(path).map_err(|_| native_error("无法创建导出文件，请选择可写的位置。"))?;
        use std::io::Write;
        file.write_all(logs.text.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|_| native_error("日志导出失败，请检查磁盘空间。"))?;
        Ok(true)
    })
    .await
    .map_err(|_| native_error("导出日志任务失败。"))?
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounds_latest_logs_and_ignores_unrelated_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("current.log"), vec![b'x'; BUDGET + 20]).unwrap();
        std::fs::write(dir.path().join("secret.json"), "not a log").unwrap();
        let logs = read_logs(dir.path()).unwrap();
        assert_eq!(logs.text.len(), BUDGET);
        assert!(logs.truncated);
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_read() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join("secret");
        std::fs::write(&secret, "secret").unwrap();
        std::os::unix::fs::symlink(secret, dir.path().join("link.log")).unwrap();
        assert!(read_logs(dir.path()).unwrap().text.is_empty());
    }
}
