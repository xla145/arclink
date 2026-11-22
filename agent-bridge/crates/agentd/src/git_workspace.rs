//! Git branch listing and workspace/worktree preparation for a paired phone.
//! Confined to folders inside the user's home directory, mirroring `directories.rs`.
use std::{
    path::{Path, PathBuf},
    process::Command,
};
use uuid::Uuid;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct GitBranchInfo {
    pub is_git_repo: bool,
    pub repo_root: Option<String>,
    pub current_branch: Option<String>,
    pub branches: Vec<String>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PreparedGitWorkspace {
    pub path: String,
    pub branch: Option<String>,
    pub is_worktree: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum GitWorkspaceError {
    Forbidden,
    Unavailable(String),
    GitFailed(String),
}

fn resolve_in_home(raw: &str, home: &Path) -> Result<PathBuf, GitWorkspaceError> {
    let home = home
        .canonicalize()
        .map_err(|_| GitWorkspaceError::Unavailable("Home directory unavailable.".into()))?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(GitWorkspaceError::Unavailable(
            "Project path is empty.".into(),
        ));
    }
    let requested = if trimmed == "~" {
        home.clone()
    } else if let Some(rest) = trimmed.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(trimmed)
    };
    let dir = requested
        .canonicalize()
        .map_err(|_| GitWorkspaceError::Unavailable("Project folder not found.".into()))?;
    if !dir.starts_with(&home) {
        return Err(GitWorkspaceError::Forbidden);
    }
    if !dir.is_dir() {
        return Err(GitWorkspaceError::Unavailable(
            "Project path is not a directory.".into(),
        ));
    }
    Ok(dir)
}

fn run_git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| format!("Failed to invoke git: {e}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        Err(if !stderr.is_empty() { stderr } else { stdout })
    }
}

fn is_safe_ref_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 160
        && !name.starts_with('-')
        && !name.contains("..")
        && !name.contains('\0')
        && !name.chars().any(|c| c.is_whitespace())
}

pub fn list_git_branches(path: &str, home: &Path) -> Result<GitBranchInfo, GitWorkspaceError> {
    let dir = resolve_in_home(path, home)?;
    let Ok(root) = run_git(&dir, &["rev-parse", "--show-toplevel"]) else {
        return Ok(GitBranchInfo {
            is_git_repo: false,
            repo_root: None,
            current_branch: None,
            branches: Vec::new(),
        });
    };
    let current = run_git(&dir, &["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .filter(|b| !b.is_empty() && b != "HEAD");
    let raw_branches = run_git(
        &dir,
        &[
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads",
        ],
    )
    .unwrap_or_default();
    let mut branches: Vec<String> = raw_branches
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(String::from)
        .take(200)
        .collect();
    if let Some(ref curr) = current {
        if let Some(pos) = branches.iter().position(|b| b == curr) {
            branches.remove(pos);
        }
        branches.insert(0, curr.clone());
    }
    Ok(GitBranchInfo {
        is_git_repo: true,
        repo_root: Some(root),
        current_branch: current,
        branches,
    })
}

pub fn prepare_git_workspace(
    path: &str,
    mode: &str,
    branch: Option<&str>,
    home: &Path,
) -> Result<PreparedGitWorkspace, GitWorkspaceError> {
    let dir = resolve_in_home(path, home)?;
    let info = list_git_branches(path, home)?;
    if !info.is_git_repo {
        return Err(GitWorkspaceError::GitFailed(
            "Selected folder is not a Git repository.".into(),
        ));
    }
    let repo_root = PathBuf::from(
        info.repo_root
            .ok_or_else(|| GitWorkspaceError::GitFailed("Unable to resolve Git root.".into()))?,
    );
    let requested_branch = branch.map(str::trim).filter(|b| !b.is_empty());
    if let Some(b) = requested_branch {
        if !is_safe_ref_name(b) {
            return Err(GitWorkspaceError::GitFailed(
                "Invalid Git branch name.".into(),
            ));
        }
    }

    match mode {
        "current" => {
            if let Some(target) = requested_branch {
                if info.current_branch.as_deref() != Some(target) {
                    run_git(&dir, &["checkout", target]).map_err(GitWorkspaceError::GitFailed)?;
                }
            }
            let active = run_git(&dir, &["rev-parse", "--abbrev-ref", "HEAD"])
                .ok()
                .filter(|b| !b.is_empty() && b != "HEAD");
            Ok(PreparedGitWorkspace {
                path: dir.to_string_lossy().into_owned(),
                branch: active,
                is_worktree: false,
            })
        }
        "worktree" => {
            let canonical_home = home.canonicalize().map_err(|_| {
                GitWorkspaceError::Unavailable("Home directory unavailable.".into())
            })?;
            let repo_name = repo_root
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("repo");
            let base_ref = requested_branch
                .or(info.current_branch.as_deref())
                .unwrap_or("HEAD");
            let short_id = &Uuid::new_v4().simple().to_string()[..6];
            let safe_base: String = base_ref
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '-' {
                        c
                    } else {
                        '-'
                    }
                })
                .take(24)
                .collect();
            let new_branch = format!("arclink/{safe_base}-{short_id}");
            let worktree_parent = canonical_home
                .join(".arclink")
                .join("worktrees")
                .join(repo_name);
            std::fs::create_dir_all(&worktree_parent).map_err(|e| {
                GitWorkspaceError::Unavailable(format!("Cannot create worktree directory: {e}"))
            })?;
            let worktree_path = worktree_parent.join(format!("{safe_base}-{short_id}"));
            let worktree_str = worktree_path.to_string_lossy().into_owned();
            run_git(
                &repo_root,
                &[
                    "worktree",
                    "add",
                    "-b",
                    &new_branch,
                    &worktree_str,
                    base_ref,
                ],
            )
            .map_err(GitWorkspaceError::GitFailed)?;
            Ok(PreparedGitWorkspace {
                path: worktree_str,
                branch: Some(new_branch),
                is_worktree: true,
            })
        }
        _ => Err(GitWorkspaceError::GitFailed(
            "Unsupported workspace mode. Expected 'current' or 'worktree'.".into(),
        )),
    }
}
