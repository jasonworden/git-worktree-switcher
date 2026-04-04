use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone)]
pub struct Worktree {
    pub path: PathBuf,
    pub branch: String,
    pub is_main: bool,
}

/// Parse `git worktree list --porcelain` output into structured data.
pub fn parse_worktree_list(porcelain: &str) -> Vec<Worktree> {
    let mut worktrees = Vec::new();
    let mut current_path: Option<PathBuf> = None;
    let mut current_branch: Option<String> = None;
    let mut main_path: Option<PathBuf> = None;
    let mut saw_head = false;

    for line in porcelain.lines() {
        if let Some(rest) = line.strip_prefix("worktree ") {
            // Emit previous worktree if any
            if let Some(path) = current_path.take() {
                let is_main = main_path.is_none();
                if is_main {
                    main_path = Some(path.clone());
                }
                let branch = current_branch
                    .take()
                    .unwrap_or_else(|| "(detached)".to_string());
                worktrees.push(Worktree {
                    path,
                    branch,
                    is_main,
                });
            }
            current_path = Some(PathBuf::from(rest));
            current_branch = None;
            saw_head = false;
        } else if let Some(rest) = line.strip_prefix("branch ") {
            let branch = rest.strip_prefix("refs/heads/").unwrap_or(rest);
            current_branch = Some(branch.to_string());
        } else if line.starts_with("HEAD ") {
            saw_head = true;
        } else if line.is_empty() {
            // blank line terminates an entry — but we handle emission at next "worktree" line
        }
        // "detached" is indicated by having a HEAD line but no branch line
        let _ = saw_head; // suppress unused warning; detection happens at emit
    }

    // Emit last worktree
    if let Some(path) = current_path {
        let is_main = main_path.is_none();
        let branch = current_branch.unwrap_or_else(|| "(detached)".to_string());
        worktrees.push(Worktree {
            path,
            branch,
            is_main,
        });
    }

    worktrees
}

/// Run `git worktree list --porcelain` and parse the output.
pub fn list_worktrees() -> Vec<Worktree> {
    let output = Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            parse_worktree_list(&stdout)
        }
        _ => Vec::new(),
    }
}

/// Return the main (first) worktree's absolute path.
pub fn main_worktree() -> Option<PathBuf> {
    list_worktrees().into_iter().find(|w| w.is_main).map(|w| w.path)
}

/// Return the branch name of the main worktree.
pub fn default_branch() -> Option<String> {
    list_worktrees()
        .into_iter()
        .find(|w| w.is_main)
        .map(|w| w.branch)
}

/// Check if a worktree path has uncommitted or untracked changes.
pub fn has_changes(wt_path: &Path) -> bool {
    let output = Command::new("git")
        .args(["-C", &wt_path.to_string_lossy(), "status", "--porcelain"])
        .output();

    match output {
        Ok(o) => !o.stdout.is_empty(),
        Err(_) => false,
    }
}

/// Count commits on `branch` that are not on `default_branch`.
pub fn unique_commits(branch: &str, default_branch: &str) -> u32 {
    let range = format!("{default_branch}..{branch}");
    let output = Command::new("git")
        .args(["log", "--oneline", &range])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            stdout.lines().count() as u32
        }
        _ => 0,
    }
}

/// Check if the remote tracking branch is gone.
pub fn remote_branch_gone(branch: &str) -> bool {
    let refspec = format!("refs/remotes/origin/{branch}");
    let output = Command::new("git")
        .args(["show-ref", "--verify", "--quiet", &refspec])
        .output();

    match output {
        Ok(o) => !o.status.success(),
        Err(_) => true,
    }
}

/// Check if `gh` CLI is installed and authenticated.
pub fn gh_available() -> bool {
    let gh_exists = Command::new("gh")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if !gh_exists {
        return false;
    }

    Command::new("gh")
        .args(["auth", "token"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_single_worktree() {
        let input = "worktree /home/user/project\nHEAD abc123\nbranch refs/heads/main\n\n";
        let wts = parse_worktree_list(input);
        assert_eq!(wts.len(), 1);
        assert_eq!(wts[0].branch, "main");
        assert_eq!(wts[0].path, PathBuf::from("/home/user/project"));
        assert!(wts[0].is_main);
    }

    #[test]
    fn parse_multiple_worktrees() {
        let input = "\
worktree /home/user/project
HEAD abc123
branch refs/heads/main

worktree /home/user/feature-x
HEAD def456
branch refs/heads/feature-x

";
        let wts = parse_worktree_list(input);
        assert_eq!(wts.len(), 2);
        assert!(wts[0].is_main);
        assert!(!wts[1].is_main);
        assert_eq!(wts[0].branch, "main");
        assert_eq!(wts[1].branch, "feature-x");
    }

    #[test]
    fn parse_detached_head() {
        let input = "worktree /home/user/project\nHEAD abc123\ndetached\n\n";
        let wts = parse_worktree_list(input);
        assert_eq!(wts.len(), 1);
        assert_eq!(wts[0].branch, "(detached)");
    }

    #[test]
    fn parse_empty_input() {
        let wts = parse_worktree_list("");
        assert!(wts.is_empty());
    }
}
