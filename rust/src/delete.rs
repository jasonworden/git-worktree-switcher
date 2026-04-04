use std::process::Command;

/// Remove a worktree by its absolute path.
pub fn run(path: &str) -> Result<(), String> {
    let status = Command::new("git")
        .args(["worktree", "remove", path])
        .status()
        .map_err(|e| format!("Failed to run git: {e}"))?;

    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "Failed to remove worktree: {path} (may have changes -- use git worktree remove --force)"
        ))
    }
}
