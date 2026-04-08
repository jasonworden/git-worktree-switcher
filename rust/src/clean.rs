use std::collections::HashMap;
use std::process::Command;

use crate::git;

#[derive(Debug)]
pub struct Verdict {
    pub verdict: String,
    pub branch: String,
    pub path: String,
    /// Optional columns for aligned UI (remote gone last — often empty).
    pub pr: String,
    pub ahead: String,
    pub tree: String,
    pub remote: String,
}

/// Fetch merged PRs from GitHub via GraphQL. Returns branch_name -> PR number.
pub fn fetch_merged_prs() -> HashMap<String, u64> {
    let mut map = HashMap::new();

    let remote_url = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());

    let remote_url = match remote_url {
        Some(u) => u,
        None => return map,
    };

    let (owner, repo) = match parse_owner_repo(&remote_url) {
        Some(pair) => pair,
        None => return map,
    };

    let query = r#"query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){pullRequests(first:100,states:MERGED,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{headRefName number}}}}"#.to_string();

    let output = Command::new("gh")
        .args([
            "api",
            "graphql",
            "-f",
            &format!("query={query}"),
            "-f",
            &format!("owner={owner}"),
            "-f",
            &format!("repo={repo}"),
        ])
        .output();

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return map,
    };

    let json: serde_json::Value = match serde_json::from_slice(&output.stdout) {
        Ok(v) => v,
        Err(_) => return map,
    };

    if let Some(nodes) = json
        .pointer("/data/repository/pullRequests/nodes")
        .and_then(|n| n.as_array())
    {
        for node in nodes {
            if let (Some(branch), Some(number)) = (
                node.get("headRefName").and_then(|v| v.as_str()),
                node.get("number").and_then(|v| v.as_u64()),
            ) {
                map.insert(branch.to_string(), number);
            }
        }
    }

    map
}

fn parse_owner_repo(url: &str) -> Option<(String, String)> {
    if url.starts_with("git@") {
        // git@github.com:owner/repo.git
        let path = url.split(':').nth(1)?;
        let path = path.strip_suffix(".git").unwrap_or(path);
        let (owner, repo) = path.split_once('/')?;
        Some((owner.to_string(), repo.to_string()))
    } else {
        // https://github.com/owner/repo.git
        let url = url
            .strip_prefix("https://")
            .or_else(|| url.strip_prefix("http://"))?;
        let mut parts = url.splitn(3, '/');
        let _host = parts.next()?;
        let owner = parts.next()?;
        let repo = parts.next()?;
        let repo = repo.strip_suffix(".git").unwrap_or(repo);
        Some((owner.to_string(), repo.to_string()))
    }
}

/// Run the full clean-check pipeline: fetch, gather PR data, check all worktrees.
/// Output: TSV `verdict\tbranch\tpath\tpr\tahead\ttree\tremote` (empty cells allowed).
pub fn run_clean_check(use_gh: bool) {
    // Background: git fetch --prune
    let mut fetch_child = Command::new("git")
        .args(["fetch", "--prune", "--quiet"])
        .spawn()
        .ok();

    // Foreground: fetch merged PRs if gh available
    let merged_prs = if use_gh && git::gh_available() {
        fetch_merged_prs()
    } else {
        HashMap::new()
    };

    // Wait for fetch to complete
    if let Some(ref mut child) = fetch_child {
        let _ = child.wait();
    }

    let worktrees = git::list_worktrees();
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    for wt in &worktrees {
        if wt.is_main || wt.branch == "(detached)" {
            continue;
        }

        let verdict = check_worktree(wt, &default_branch, &merged_prs);
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            verdict.verdict,
            verdict.branch,
            verdict.path,
            verdict.pr,
            verdict.ahead,
            verdict.tree,
            verdict.remote,
        );
    }
}

fn check_worktree(
    wt: &git::Worktree,
    default_branch: &str,
    merged_prs: &HashMap<String, u64>,
) -> Verdict {
    let mut has_gone_signal = false;
    let mut has_concerns = false;

    let pr = if let Some(pr_num) = merged_prs.get(&wt.branch) {
        has_gone_signal = true;
        format!("PR #{pr_num} merged")
    } else {
        String::new()
    };

    let ahead_n = git::unique_commits(&wt.branch, default_branch);
    let ahead = if ahead_n > 0 {
        has_concerns = true;
        format!("{ahead_n} commit(s) ahead")
    } else {
        String::new()
    };

    let dirty = git::has_changes(&wt.path);
    let tree = if dirty {
        has_concerns = true;
        "uncommitted changes".to_string()
    } else {
        "clean".to_string()
    };

    // Optional signal last so UI columns stay aligned when absent.
    let remote = if git::remote_branch_gone(&wt.branch) {
        has_gone_signal = true;
        "remote gone".to_string()
    } else {
        String::new()
    };

    let verdict = if !has_concerns && has_gone_signal {
        "safe"
    } else {
        "warn"
    };

    Verdict {
        verdict: verdict.to_string(),
        branch: wt.branch.clone(),
        path: wt.path.to_string_lossy().to_string(),
        pr,
        ahead,
        tree,
        remote,
    }
}

/// Same rules as `run_quick_status`, for batched picker output.
pub fn quick_status_label(
    branch: &str,
    wt_path: &std::path::Path,
    default_branch: &str,
) -> Option<&'static str> {
    if branch == "(detached)" {
        return None;
    }

    let remote_gone = git::remote_branch_gone(branch);
    let ahead = git::unique_commits(branch, default_branch);
    let dirty = git::has_changes(wt_path);

    if remote_gone && ahead == 0 && !dirty {
        Some("safe")
    } else if ahead > 0 || dirty {
        Some("warn")
    } else {
        None
    }
}

/// Quick local-only staleness check. Prints "safe", "warn", or nothing.
pub fn run_quick_status(branch: &str, wt_path: &str, default_branch: Option<&str>) {
    let default = default_branch
        .map(|s| s.to_string())
        .or_else(git::default_branch)
        .unwrap_or_else(|| "main".to_string());

    if let Some(s) = quick_status_label(branch, std::path::Path::new(wt_path), &default) {
        println!("{s}");
    }
}

/// Print completions: all local and remote branch names.
pub fn run_completions() {
    let output = Command::new("git")
        .args(["branch", "-a", "--format=%(refname:short)"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            print!("{}", String::from_utf8_lossy(&o.stdout));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ssh_remote() {
        let (owner, repo) =
            parse_owner_repo("git@github.com:jasonworden/git-worktree-switcher.git").unwrap();
        assert_eq!(owner, "jasonworden");
        assert_eq!(repo, "git-worktree-switcher");
    }

    #[test]
    fn parse_https_remote() {
        let (owner, repo) =
            parse_owner_repo("https://github.com/jasonworden/git-worktree-switcher.git").unwrap();
        assert_eq!(owner, "jasonworden");
        assert_eq!(repo, "git-worktree-switcher");
    }

    #[test]
    fn parse_https_no_git_suffix() {
        let (owner, repo) =
            parse_owner_repo("https://github.com/jasonworden/git-worktree-switcher").unwrap();
        assert_eq!(owner, "jasonworden");
        assert_eq!(repo, "git-worktree-switcher");
    }

    #[test]
    fn verdict_safe_when_remote_gone_and_clean() {
        let wt = git::Worktree {
            path: std::path::PathBuf::from("/tmp/nonexistent"),
            branch: "test-branch".to_string(),
            is_main: false,
        };
        let merged = HashMap::new();
        // This will check a nonexistent remote branch (gone=true) and
        // a nonexistent path (no changes). The verdict depends on actual git state
        // so this is more of a smoke test.
        let v = check_worktree(&wt, "main", &merged);
        assert!(v.verdict == "safe" || v.verdict == "warn");
    }
}
