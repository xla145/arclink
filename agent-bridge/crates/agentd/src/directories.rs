//! Folder browsing for a paired phone choosing a project path. Read-only,
//! folders only, and confined to the user's home directory: a symlink or
//! `..` that resolves outside it is refused rather than followed.
use std::path::{Path, PathBuf};

/// Upper bound on entries returned for one folder; a phone list, not a crawler.
pub const MAX_ENTRIES: usize = 400;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
    /// Contains a `.git` entry, i.e. very likely a project root.
    pub is_project: bool,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct DirectoryListing {
    pub path: String,
    /// `None` at the home directory: browsing never goes above it.
    pub parent: Option<String>,
    pub entries: Vec<DirectoryEntry>,
    /// More subfolders exist than `MAX_ENTRIES`.
    pub truncated: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DirectoryError {
    /// Outside the home directory (after resolving symlinks and `~`).
    Forbidden,
    /// Missing, not a folder, or unreadable.
    Unavailable,
}

/// `home` stands in for the user's home directory so tests never touch the
/// real one. `path` may be absolute, `~`, or `~/…`; `None` means home.
pub fn list_directory(path: Option<&str>, home: &Path) -> Result<DirectoryListing, DirectoryError> {
    let home = home.canonicalize().map_err(|_| DirectoryError::Unavailable)?;
    let requested = match path.map(str::trim).filter(|p| !p.is_empty()) {
        None | Some("~") => home.clone(),
        Some(p) if p.starts_with("~/") => home.join(&p[2..]),
        Some(p) => PathBuf::from(p),
    };
    let dir = requested.canonicalize().map_err(|_| DirectoryError::Unavailable)?;
    if !dir.starts_with(&home) {
        return Err(DirectoryError::Forbidden);
    }
    if !dir.is_dir() {
        return Err(DirectoryError::Unavailable);
    }
    let reader = std::fs::read_dir(&dir).map_err(|_| DirectoryError::Unavailable)?;
    let mut entries = Vec::new();
    let mut truncated = false;
    for item in reader.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        // Follow symlinks only when they still land inside home.
        let Ok(target) = item.path().canonicalize() else { continue };
        if !target.starts_with(&home) || !target.is_dir() {
            continue;
        }
        if entries.len() == MAX_ENTRIES {
            truncated = true;
            break;
        }
        entries.push(DirectoryEntry {
            is_project: item.path().join(".git").exists(),
            path: item.path().to_string_lossy().into_owned(),
            name,
        });
    }
    entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    let parent = (dir != home)
        .then(|| dir.parent().map(|p| p.to_string_lossy().into_owned()))
        .flatten();
    Ok(DirectoryListing { path: dir.to_string_lossy().into_owned(), parent, entries, truncated })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        std::fs::create_dir_all(home.join("work/app/.git")).unwrap();
        std::fs::create_dir_all(home.join("work/notes")).unwrap();
        std::fs::create_dir_all(home.join(".config")).unwrap();
        std::fs::create_dir_all(root.path().join("outside")).unwrap();
        std::fs::write(home.join("readme.txt"), "x").unwrap();
        let home = home.canonicalize().unwrap();
        (root, home)
    }

    #[test]
    fn lists_only_visible_folders_and_marks_projects() {
        let (_root, home) = home();
        let top = list_directory(None, &home).unwrap();
        assert_eq!(top.path, home.to_string_lossy());
        assert_eq!(top.parent, None);
        assert_eq!(top.entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["work"]);
        let work = list_directory(Some("~/work"), &home).unwrap();
        assert_eq!(work.parent.as_deref(), Some(home.to_string_lossy().as_ref()));
        let names: Vec<_> = work.entries.iter().map(|e| (e.name.as_str(), e.is_project)).collect();
        assert_eq!(names, [("app", true), ("notes", false)]);
    }

    #[test]
    fn refuses_paths_and_symlinks_outside_home() {
        let (root, home) = home();
        assert_eq!(list_directory(Some(root.path().to_str().unwrap()), &home), Err(DirectoryError::Forbidden));
        assert_eq!(list_directory(Some("~/work/../.."), &home), Err(DirectoryError::Forbidden));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.path().join("outside"), home.join("escape")).unwrap();
            assert_eq!(list_directory(Some("~/escape"), &home), Err(DirectoryError::Forbidden));
            assert!(list_directory(None, &home).unwrap().entries.iter().all(|e| e.name != "escape"));
        }
    }

    #[test]
    fn missing_paths_and_files_are_unavailable() {
        let (_root, home) = home();
        assert_eq!(list_directory(Some("~/nope"), &home), Err(DirectoryError::Unavailable));
        assert_eq!(list_directory(Some("~/readme.txt"), &home), Err(DirectoryError::Unavailable));
    }
}
