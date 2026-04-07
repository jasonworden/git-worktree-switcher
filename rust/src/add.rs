use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

use crate::config;
use crate::git;

/// Create a new worktree. Uses config for path convention.
/// Prints the target path on success.
pub fn run(branch: &str) -> Result<(), String> {
    let cfg = config::load();
    let main_wt = git::main_worktree().ok_or("Not in a git repository")?;
    let basedir = config::resolve_basedir(&cfg, &main_wt);
    let target = basedir.join(branch);

    // Ensure basedir exists
    if !basedir.exists() {
        fs::create_dir_all(&basedir)
            .map_err(|e| format!("Failed to create directory {}: {e}", basedir.display()))?;
    }

    // Auto-gitignore
    ensure_gitignore(&main_wt, &cfg);

    let exists = Command::new("git")
        .args([
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    let status = if exists {
        Command::new("git")
            .args(["worktree", "add", &target.to_string_lossy(), branch])
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .status()
    } else {
        Command::new("git")
            .args(["worktree", "add", "-b", branch, &target.to_string_lossy()])
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .status()
    };

    match status {
        Ok(s) if s.success() => {
            println!("{}", target.display());
            Ok(())
        }
        Ok(s) => Err(format!("git worktree add failed with exit code {}", s)),
        Err(e) => Err(format!("Failed to run git: {e}")),
    }
}

/// Ensure .worktrees/ and .claude/worktrees/ are in .gitignore.
fn ensure_gitignore(main_wt: &Path, cfg: &config::Config) {
    let gitignore_path = main_wt.join(".gitignore");
    let entries = [".worktrees/", ".claude/worktrees/"];

    let existing = fs::read_to_string(&gitignore_path).unwrap_or_default();
    let mut to_add = Vec::new();

    for entry in &entries {
        if !existing.lines().any(|line| line.trim() == *entry) {
            to_add.push(*entry);
        }
    }

    if to_add.is_empty() {
        return;
    }

    // In non-opinionated mode without auto_gitignore, skip silently
    // (the zsh wrapper will prompt the user)
    if !cfg.auto_gitignore {
        return;
    }

    let mut content = existing;
    if !content.is_empty() && !content.ends_with('\n') {
        content.push('\n');
    }
    for entry in &to_add {
        content.push_str(entry);
        content.push('\n');
    }
    let _ = fs::write(&gitignore_path, content);
}
