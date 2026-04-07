use std::collections::HashMap;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::clean;
use crate::config;
use crate::entries;
use crate::git;

// ANSI color codes
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const CYAN: &str = "\x1b[36m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";
const BULLET: &str = "\u{25cf}"; // ●
const CHECK: &str = "\u{2713}"; // ✓
const MDASH: &str = "\u{2014}"; // —
const DOTS: &str = "\u{b7}\u{b7}"; // ··

/// Worktree row data (shared between local and remote).
struct Row {
    branch: String,
    rel: String,
    abs: String,
    tree: String,
    ahead: String,
    remote: String,
    pr: String,
    verdict: String,
    is_main: bool,
    stale: bool,
}

const STALE_THRESHOLD_SECS: u64 = 14 * 24 * 60 * 60; // 2 weeks

/// Check if the last commit on a branch is older than 2 weeks.
fn is_stale(path: &str) -> bool {
    let output = Command::new("git")
        .args(["-C", path, "log", "-1", "--format=%ct"])
        .output()
        .ok();
    let timestamp: u64 = output
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse().ok())
        .unwrap_or(0);
    if timestamp == 0 {
        return false;
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    now.saturating_sub(timestamp) > STALE_THRESHOLD_SECS
}

/// Gather local-only data (instant, no network).
fn gather_local() -> Vec<Row> {
    let cfg = config::load();
    let worktrees = git::list_worktrees();
    let main_path = worktrees.iter().find(|w| w.is_main).map(|w| w.path.clone());
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    worktrees
        .iter()
        .map(|wt| {
            let rel = entries::worktree_rel(wt, main_path.as_ref());
            let dirty = git::has_changes(&wt.path);
            let tree = if dirty { "dirty" } else { "clean" }.to_string();

            let ahead = if wt.is_main {
                MDASH.to_string()
            } else {
                let n = git::unique_commits(&wt.branch, &default_branch);
                if n > 0 {
                    n.to_string()
                } else {
                    MDASH.to_string()
                }
            };

            let abs = wt.path.to_string_lossy().to_string();
            let stale = !wt.is_main && cfg.stale_warning && is_stale(&abs);

            Row {
                branch: wt.branch.clone(),
                rel,
                abs,
                tree,
                ahead,
                remote: DOTS.to_string(),
                pr: DOTS.to_string(),
                verdict: if wt.is_main {
                    "pinned".to_string()
                } else {
                    "pending".to_string()
                },
                is_main: wt.is_main,
                stale,
            }
        })
        .collect()
}

/// Gather remote-enriched data (fetch + GH API).
fn gather_remote() -> Vec<Row> {
    let cfg = config::load();

    // Background: git fetch --prune
    let mut fetch_child = Command::new("git")
        .args(["fetch", "--prune", "--quiet"])
        .spawn()
        .ok();

    let has_remote = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    let gh_ok = has_remote && git::gh_available();
    let merged_prs = if gh_ok {
        clean::fetch_merged_prs()
    } else {
        HashMap::new()
    };

    if let Some(ref mut child) = fetch_child {
        let _ = child.wait();
    }

    let worktrees = git::list_worktrees();
    let main_path = worktrees.iter().find(|w| w.is_main).map(|w| w.path.clone());
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    worktrees
        .iter()
        .map(|wt| {
            let rel = entries::worktree_rel(wt, main_path.as_ref());
            let dirty = git::has_changes(&wt.path);
            let tree = if dirty { "dirty" } else { "clean" }.to_string();

            let abs = wt.path.to_string_lossy().to_string();

            if wt.is_main {
                return Row {
                    branch: wt.branch.clone(),
                    rel,
                    abs,
                    tree,
                    ahead: MDASH.to_string(),
                    remote: MDASH.to_string(),
                    pr: MDASH.to_string(),
                    verdict: "pinned".to_string(),
                    is_main: true,
                    stale: false,
                };
            }

            let ahead_n = git::unique_commits(&wt.branch, &default_branch);
            let ahead = if ahead_n > 0 {
                ahead_n.to_string()
            } else {
                MDASH.to_string()
            };

            let remote_gone = has_remote && git::remote_branch_gone(&wt.branch);
            let remote = if !has_remote {
                "no remote".to_string()
            } else if remote_gone {
                "gone".to_string()
            } else {
                format!("origin {CHECK}")
            };

            let pr_merged = merged_prs.contains_key(&wt.branch);
            let pr = if !has_remote {
                MDASH.to_string()
            } else if let Some(pr_num) = merged_prs.get(&wt.branch) {
                format!("#{pr_num} merged")
            } else if !gh_ok {
                "no gh".to_string()
            } else {
                "no PR".to_string()
            };

            let has_gone_signal = remote_gone || pr_merged;
            let has_concerns = ahead_n > 0 || dirty;
            let verdict = match (has_concerns, has_gone_signal) {
                (false, true) => "safe",
                (true, true) => "keep",
                (true, false) => "unsafe",
                (false, false) => "keep",
            };

            let stale = cfg.stale_warning && is_stale(&abs);

            Row {
                branch: wt.branch.clone(),
                rel,
                abs,
                tree,
                ahead,
                remote,
                pr,
                verdict: verdict.to_string(),
                is_main: false,
                stale,
            }
        })
        .collect()
}

/// Format a row for browse mode display (ANSI colored, tab-separated from abs path).
fn format_browse(row: &Row) -> String {
    let indicator = if row.is_main {
        format!("{GREEN}{BULLET}{RESET}")
    } else {
        " ".to_string()
    };

    let stale_tag = if row.stale {
        format!(" {YELLOW}stale{RESET}")
    } else {
        String::new()
    };

    let branch_col = if row.is_main {
        format!("{GREEN}{}{RESET}", row.branch)
    } else {
        format!("{CYAN}{}{RESET}{stale_tag}", row.branch)
    };

    let tree_col = if row.tree == "clean" {
        format!("{GREEN}clean{RESET}")
    } else {
        format!("{RED}dirty{RESET}")
    };

    let ahead_col = if row.ahead == MDASH {
        format!("{DIM}{MDASH}{RESET}")
    } else {
        format!("{YELLOW}{}{RESET}", row.ahead)
    };

    let remote_col = match row.remote.as_str() {
        s if s.contains("gone") => format!("{RED}gone{RESET}"),
        s if s.contains("origin") => format!("{GREEN}origin {CHECK}{RESET}"),
        s if s == DOTS => format!("{DIM}{DOTS}{RESET}"),
        _ => format!("{DIM}{}{RESET}", row.remote),
    };

    let pr_col = match row.pr.as_str() {
        s if s.contains("merged") => format!("{GREEN}{}{RESET}", row.pr),
        s if s == DOTS => format!("{DIM}{DOTS}{RESET}"),
        _ => format!("{DIM}{}{RESET}", row.pr),
    };

    format!(
        "{} {:<20} {DIM}{:<24}{RESET} {:<7} {:<7} {:<12} {}\t{}",
        indicator, branch_col, row.rel, tree_col, ahead_col, remote_col, pr_col, row.abs,
    )
}

/// Format a row for uproot mode display (with verdict column).
fn format_uproot(row: &Row) -> String {
    if row.is_main {
        return format!(
            "{DIM}  {:<20} {:<24} {:<7} {:<7} {:<12} {:<14} pinned{RESET}\t{}",
            row.branch, row.rel, row.tree, row.ahead, row.remote, row.pr, row.abs,
        );
    }

    let stale_tag = if row.stale {
        format!(" {YELLOW}stale{RESET}")
    } else {
        String::new()
    };
    let branch_col = format!("{CYAN}{}{RESET}{stale_tag}", row.branch);
    let tree_col = if row.tree == "clean" {
        format!("{GREEN}clean{RESET}")
    } else {
        format!("{RED}dirty{RESET}")
    };
    let ahead_col = if row.ahead == MDASH {
        format!("{DIM}{MDASH}{RESET}")
    } else {
        format!("{YELLOW}{}{RESET}", row.ahead)
    };
    let remote_col = match row.remote.as_str() {
        s if s.contains("gone") => format!("{RED}gone{RESET}"),
        s if s.contains("origin") => format!("{GREEN}origin {CHECK}{RESET}"),
        s if s == DOTS => format!("{DIM}{DOTS}{RESET}"),
        _ => format!("{DIM}{}{RESET}", row.remote),
    };
    let pr_col = match row.pr.as_str() {
        s if s.contains("merged") => format!("{GREEN}{}{RESET}", row.pr),
        s if s == DOTS => format!("{DIM}{DOTS}{RESET}"),
        _ => format!("{DIM}{}{RESET}", row.pr),
    };
    let verdict_col = match row.verdict.as_str() {
        "safe" => format!("{GREEN}safe {CHECK}{RESET}"),
        "keep" => format!("{YELLOW}keep{RESET}"),
        "unsafe" => format!("{RED}unsafe{RESET}"),
        "pending" => format!("{DIM}...{RESET}"),
        v => format!("{DIM}{v}{RESET}"),
    };

    format!(
        "  {:<20} {DIM}{:<24}{RESET} {:<7} {:<7} {:<12} {:<14} {}\t{}",
        branch_col, row.rel, tree_col, ahead_col, remote_col, pr_col, verdict_col, row.abs,
    )
}

/// Public entry: --local with optional --format
pub fn run_local_formatted(format: &str) {
    let rows = gather_local();
    output_rows(&rows, format);
}

/// Public entry: --remote with optional --format
pub fn run_remote_formatted(format: &str) {
    let rows = gather_remote();
    output_rows(&rows, format);
}

fn output_rows(rows: &[Row], format: &str) {
    for row in rows {
        match format {
            "browse" => println!("{}", format_browse(row)),
            "uproot" => println!("{}", format_uproot(row)),
            _ => {
                // Raw TSV
                println!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    row.branch,
                    row.rel,
                    row.abs,
                    row.tree,
                    row.ahead,
                    row.remote,
                    row.pr,
                    row.verdict,
                    row.is_main,
                    row.stale,
                );
            }
        }
    }
}

/// Output preview info for a single worktree.
pub fn run_preview(path: &str) {
    let branch = Command::new("git")
        .args(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let last_date = Command::new("git")
        .args(["-C", path, "log", "-1", "--format=%cr"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();

    println!("{branch}  last touched {last_date}");
    println!("{}", "\u{2500}".repeat(40));

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

    let stash = Command::new("git")
        .args(["-C", path, "stash", "list"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().count())
        .unwrap_or(0);

    if stash > 0 {
        println!("\n{stash} stash(es)");
    }
}

/// List remote branches not yet checked out as worktrees (for plant mode).
pub fn run_branches() {
    let worktrees = git::list_worktrees();
    let wt_branches: Vec<&str> = worktrees.iter().map(|w| w.branch.as_str()).collect();

    let output = Command::new("git")
        .args(["branch", "-r", "--format=%(refname:short)"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            let stdout = String::from_utf8_lossy(&o.stdout);
            println!("[new branch]");
            for line in stdout.lines() {
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
