use std::collections::HashMap;
use std::process::Command;

use crate::clean;
use crate::config;
use crate::entries;
use crate::git;

/// Output TSV: branch \t rel_path \t abs_path \t tree \t ahead \t remote \t pr \t verdict \t is_main
/// In --local mode, remote/pr columns are "··" and verdict is "pending" or "pinned".
pub fn run_local() {
    let worktrees = git::list_worktrees();
    let main_path = worktrees.iter().find(|w| w.is_main).map(|w| w.path.clone());
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    for wt in &worktrees {
        let rel = entries::worktree_rel(wt, main_path.as_ref());

        let (tree, ahead) = if wt.is_main {
            let dirty = git::has_changes(&wt.path);
            let tree = if dirty { "dirty" } else { "clean" };
            (tree.to_string(), "\u{2014}".to_string()) // em dash
        } else {
            let dirty = git::has_changes(&wt.path);
            let tree = if dirty { "dirty" } else { "clean" };
            let ahead_n = git::unique_commits(&wt.branch, &default_branch);
            let ahead = if ahead_n > 0 {
                ahead_n.to_string()
            } else {
                "\u{2014}".to_string()
            };
            (tree.to_string(), ahead)
        };

        let verdict = if wt.is_main { "pinned" } else { "pending" };

        println!(
            "{}\t{}\t{}\t{}\t{}\t\u{b7}\u{b7}\t\u{b7}\u{b7}\t{}\t{}",
            wt.branch,
            rel,
            wt.path.display(),
            tree,
            ahead,
            verdict,
            wt.is_main,
        );
    }
}

/// Output TSV with all columns filled after fetch + GH API check.
pub fn run_remote() {
    // Background: git fetch --prune
    let mut fetch_child = Command::new("git")
        .args(["fetch", "--prune", "--quiet"])
        .spawn()
        .ok();

    // Check if remote exists
    let has_remote = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    // Foreground: fetch merged PRs if gh available
    let merged_prs = if has_remote && git::gh_available() {
        clean::fetch_merged_prs()
    } else {
        HashMap::new()
    };

    // Wait for fetch to complete
    if let Some(ref mut child) = fetch_child {
        let _ = child.wait();
    }

    let worktrees = git::list_worktrees();
    let main_path = worktrees.iter().find(|w| w.is_main).map(|w| w.path.clone());
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    for wt in &worktrees {
        let rel = entries::worktree_rel(wt, main_path.as_ref());

        if wt.is_main {
            let dirty = git::has_changes(&wt.path);
            let tree = if dirty { "dirty" } else { "clean" };
            println!(
                "{}\t{}\t{}\t{}\t\u{2014}\t\u{2014}\t\u{2014}\tpinned\ttrue",
                wt.branch,
                rel,
                wt.path.display(),
                tree,
            );
            continue;
        }

        let dirty = git::has_changes(&wt.path);
        let tree = if dirty { "dirty" } else { "clean" };
        let ahead_n = git::unique_commits(&wt.branch, &default_branch);
        let ahead = if ahead_n > 0 {
            ahead_n.to_string()
        } else {
            "\u{2014}".to_string()
        };

        let remote = if !has_remote {
            "no remote".to_string()
        } else if git::remote_branch_gone(&wt.branch) {
            "gone".to_string()
        } else {
            "origin \u{2713}".to_string()
        };

        let pr = if !has_remote {
            "\u{2014}".to_string()
        } else if let Some(pr_num) = merged_prs.get(&wt.branch) {
            format!("#{pr_num} merged")
        } else if !git::gh_available() {
            "no gh".to_string()
        } else {
            "no PR".to_string()
        };

        // Verdict logic
        let remote_gone = !has_remote || git::remote_branch_gone(&wt.branch);
        let pr_merged = merged_prs.contains_key(&wt.branch);
        let has_gone_signal = remote_gone || pr_merged;
        let has_concerns = ahead_n > 0 || dirty;

        let verdict = if !has_concerns && has_gone_signal {
            "safe"
        } else if has_concerns && has_gone_signal {
            "keep"
        } else if has_concerns {
            "unsafe"
        } else {
            "keep" // no signal either way, keep by default
        };

        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\tfalse",
            wt.branch, rel, wt.path.display(), tree, ahead, remote, pr, verdict,
        );
    }
}

/// Output preview info for a single worktree: recent commits, diff stat, stash count.
pub fn run_preview(path: &str) {
    let wt_path = std::path::Path::new(path);

    // Branch name
    let branch = Command::new("git")
        .args(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    // Last commit date
    let last_date = Command::new("git")
        .args(["-C", path, "log", "-1", "--format=%cr"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    println!("{branch}  last touched {last_date}");
    println!("{}", "\u{2500}".repeat(40));

    // Recent commits
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());
    let range = format!("{default_branch}..{branch}");
    let commits = Command::new("git")
        .args(["-C", path, "log", "--oneline", "-5", &range])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    if !commits.is_empty() {
        println!("Recent commits:");
        for line in commits.lines() {
            println!(" {line}");
        }
    } else {
        println!("No unique commits");
    }

    // Diff stat
    let diff_stat = Command::new("git")
        .args(["-C", path, "diff", "--stat", &default_branch])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    if !diff_stat.is_empty() {
        println!("\nChanged files:");
        for line in diff_stat.lines() {
            println!(" {line}");
        }
    }

    // Stash count
    let stash = Command::new("git")
        .args(["-C", path, "stash", "list"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .count()
        })
        .unwrap_or(0);

    if stash > 0 {
        println!("\n{stash} stash(es)");
    }
}

/// List remote branches not yet checked out as worktrees (for plant mode).
pub fn run_branches() {
    let worktrees = git::list_worktrees();
    let wt_branches: Vec<&str> = worktrees.iter().map(|w| w.branch.as_str()).collect();

    // Get remote branches
    let output = Command::new("git")
        .args(["branch", "-r", "--format=%(refname:short)"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            let stdout = String::from_utf8_lossy(&o.stdout);
            // Print "[new branch]" as first option
            println!("[new branch]");
            for line in stdout.lines() {
                // Strip origin/ prefix
                let branch = line.strip_prefix("origin/").unwrap_or(line);
                if branch == "HEAD" {
                    continue;
                }
                if !wt_branches.contains(&branch) {
                    println!("{branch}");
                }
            }
        }
    }
}
