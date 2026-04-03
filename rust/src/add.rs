use std::process::Command;

use crate::git;

/// Create a new worktree. If the branch exists locally, check it out;
/// otherwise create a new branch. Prints the target path on success.
pub fn run(branch: &str) -> Result<(), String> {
    let main_wt = git::main_worktree().ok_or("Not in a git repository")?;
    let parent = main_wt
        .parent()
        .ok_or("Cannot determine parent directory")?;
    let target = parent.join(branch);

    let exists = Command::new("git")
        .args(["show-ref", "--verify", "--quiet", &format!("refs/heads/{branch}")])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    let status = if exists {
        Command::new("git")
            .args(["worktree", "add", &target.to_string_lossy(), branch])
            .status()
    } else {
        Command::new("git")
            .args([
                "worktree",
                "add",
                "-b",
                branch,
                &target.to_string_lossy(),
            ])
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
