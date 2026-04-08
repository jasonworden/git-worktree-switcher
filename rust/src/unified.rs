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

/// Gather instant data — only `git worktree list` (single subprocess).
/// Defers dirty/ahead/stale checks to the remote pass.
fn gather_local() -> Vec<Row> {
    let worktrees = git::list_worktrees();
    let main_path = worktrees.iter().find(|w| w.is_main).map(|w| w.path.clone());

    worktrees
        .iter()
        .map(|wt| {
            let rel = entries::worktree_rel(wt, main_path.as_ref());
            let abs = wt.path.to_string_lossy().to_string();

            Row {
                branch: wt.branch.clone(),
                rel,
                abs,
                tree: DOTS.to_string(),
                ahead: DOTS.to_string(),
                remote: DOTS.to_string(),
                pr: DOTS.to_string(),
                verdict: if wt.is_main {
                    "pinned".to_string()
                } else {
                    "pending".to_string()
                },
                is_main: wt.is_main,
                stale: false,
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

// -- Dynamic column widths --

struct ColWidths {
    branch: usize,
    rel: usize,
    tree: usize,
    ahead: usize,
    remote: usize,
    pr: usize,
    verdict: usize,
}

fn compute_widths(rows: &[Row], include_verdict: bool) -> ColWidths {
    let mut w = ColWidths {
        branch: 6,  // "BRANCH"
        rel: 4,     // "PATH"
        tree: 4,    // "TREE"
        ahead: 9,   // "+COMMITS"
        remote: 6,  // "REMOTE"
        pr: 2,      // "PR"
        verdict: 7, // "VERDICT"
    };
    for r in rows {
        let blen = r.branch.len() + if r.stale { 6 } else { 0 }; // " stale"
        w.branch = w.branch.max(blen);
        w.rel = w.rel.max(r.rel.len());
        w.tree = w.tree.max(r.tree.len());
        w.ahead = w.ahead.max(r.ahead.len());
        w.remote = w.remote.max(r.remote.len());
        w.pr = w.pr.max(r.pr.len());
        if include_verdict {
            let vlen = match r.verdict.as_str() {
                "safe" => 6, // "safe ✓"
                v => v.len(),
            };
            w.verdict = w.verdict.max(vlen);
        }
    }
    w
}

/// Pad a plain string to width, then wrap with ANSI color.
fn colored(text: &str, color: &str, width: usize) -> String {
    format!("{color}{text:<width$}{RESET}")
}

/// Format column header row (pinned by fzf --header-lines=1).
fn format_header(w: &ColWidths, include_verdict: bool) -> String {
    let branch_col = colored("BRANCH", DIM, w.branch);
    let rel_col = colored("PATH", DIM, w.rel);
    let tree_col = colored("TREE", DIM, w.tree);
    let ahead_col = colored("+COMMITS", DIM, w.ahead);
    let remote_col = colored("REMOTE", DIM, w.remote);
    let pr_col = colored("PR", DIM, w.pr);

    if include_verdict {
        let verdict_col = colored("VERDICT", DIM, w.verdict);
        format!(
            "  {branch_col}  {rel_col}  {tree_col}  {ahead_col}  {remote_col}  {pr_col}  {verdict_col}\t."
        )
    } else {
        format!(
            "  {branch_col}  {rel_col}  {tree_col}  {ahead_col}  {remote_col}  {pr_col}\t."
        )
    }
}

/// Format a row for browse mode display.
fn format_browse(row: &Row, w: &ColWidths) -> String {
    let indicator = if row.is_main {
        format!("{GREEN}{BULLET}{RESET}")
    } else {
        " ".to_string()
    };

    let stale_suffix = if row.stale { " stale" } else { "" };
    let branch_text = format!("{}{stale_suffix}", row.branch);
    let branch_col = if row.is_main {
        colored(&branch_text, GREEN, w.branch)
    } else if row.stale {
        // branch in cyan, "stale" in yellow
        let pad = w.branch.saturating_sub(branch_text.len());
        format!(
            "{CYAN}{}{RESET} {YELLOW}stale{RESET}{:pad$}",
            row.branch,
            "",
            pad = pad
        )
    } else {
        colored(&branch_text, CYAN, w.branch)
    };

    let rel_col = colored(&row.rel, DIM, w.rel);
    let tree_col = if row.tree == "dirty" {
        colored(&row.tree, RED, w.tree)
    } else {
        colored(&row.tree, GREEN, w.tree)
    };
    let ahead_col = if row.ahead == MDASH || row.ahead == DOTS {
        colored(&row.ahead, DIM, w.ahead)
    } else {
        colored(&row.ahead, YELLOW, w.ahead)
    };
    let remote_col = if row.remote.contains("gone") {
        colored(&row.remote, RED, w.remote)
    } else if row.remote.contains("origin") {
        colored(&row.remote, GREEN, w.remote)
    } else {
        colored(&row.remote, DIM, w.remote)
    };
    let pr_col = if row.pr.contains("merged") {
        colored(&row.pr, GREEN, w.pr)
    } else {
        colored(&row.pr, DIM, w.pr)
    };

    format!(
        "{indicator} {branch_col}  {rel_col}  {tree_col}  {ahead_col}  {remote_col}  {pr_col}\t{abs}",
        abs = row.abs,
    )
}

/// Format a row for uproot mode display (with verdict column).
fn format_uproot(row: &Row, w: &ColWidths) -> String {
    if row.is_main {
        let branch_col = format!("{DIM}{:<w$}{RESET}", row.branch, w = w.branch);
        let rel_col = format!("{DIM}{:<w$}{RESET}", row.rel, w = w.rel);
        let tree_col = format!("{DIM}{:<w$}{RESET}", row.tree, w = w.tree);
        let ahead_col = format!("{DIM}{:<w$}{RESET}", row.ahead, w = w.ahead);
        let remote_col = format!("{DIM}{:<w$}{RESET}", row.remote, w = w.remote);
        let pr_col = format!("{DIM}{:<w$}{RESET}", row.pr, w = w.pr);
        let verdict_col = format!("{DIM}{:<w$}{RESET}", "pinned", w = w.verdict);
        return format!(
            "  {branch_col}  {rel_col}  {tree_col}  {ahead_col}  {remote_col}  {pr_col}  {verdict_col}\t{abs}",
            abs = row.abs,
        );
    }

    let stale_suffix = if row.stale { " stale" } else { "" };
    let branch_text = format!("{}{stale_suffix}", row.branch);
    let branch_col = if row.stale {
        let pad = w.branch.saturating_sub(branch_text.len());
        format!(
            "{CYAN}{}{RESET} {YELLOW}stale{RESET}{:pad$}",
            row.branch,
            "",
            pad = pad
        )
    } else {
        colored(&branch_text, CYAN, w.branch)
    };

    let rel_col = colored(&row.rel, DIM, w.rel);
    let tree_col = if row.tree == "dirty" {
        colored(&row.tree, RED, w.tree)
    } else {
        colored(&row.tree, GREEN, w.tree)
    };
    let ahead_col = if row.ahead == MDASH || row.ahead == DOTS {
        colored(&row.ahead, DIM, w.ahead)
    } else {
        colored(&row.ahead, YELLOW, w.ahead)
    };
    let remote_col = if row.remote.contains("gone") {
        colored(&row.remote, RED, w.remote)
    } else if row.remote.contains("origin") {
        colored(&row.remote, GREEN, w.remote)
    } else {
        colored(&row.remote, DIM, w.remote)
    };
    let pr_col = if row.pr.contains("merged") {
        colored(&row.pr, GREEN, w.pr)
    } else {
        colored(&row.pr, DIM, w.pr)
    };

    let verdict_text = match row.verdict.as_str() {
        "safe" => format!("safe {CHECK}"),
        v => v.to_string(),
    };
    let verdict_col = match row.verdict.as_str() {
        "safe" => colored(&verdict_text, GREEN, w.verdict),
        "keep" => colored(&verdict_text, YELLOW, w.verdict),
        "unsafe" => colored(&verdict_text, RED, w.verdict),
        _ => colored(&verdict_text, DIM, w.verdict),
    };

    format!(
        "  {branch_col}  {rel_col}  {tree_col}  {ahead_col}  {remote_col}  {pr_col}  {verdict_col}\t{abs}",
        abs = row.abs,
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
    match format {
        "browse" => {
            let w = compute_widths(rows, false);
            println!("{}", format_header(&w, false));
            for row in rows {
                println!("{}", format_browse(row, &w));
            }
        }
        "uproot" => {
            let mut sorted: Vec<&Row> = rows.iter().collect();
            sorted.sort_by_key(|r| match r.verdict.as_str() {
                "pinned" => 0,
                "safe" => 1,
                "keep" => 2,
                "unsafe" => 3,
                _ => 4,
            });
            let w = compute_widths(rows, true);
            println!("{}", format_header(&w, true));
            for row in sorted {
                println!("{}", format_uproot(row, &w));
            }
        }
        _ => {
            for row in rows {
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
/// Streams output immediately so fzf shows results while loading.
pub fn run_branches() {
    let worktrees = git::list_worktrees();
    let wt_branches: Vec<&str> = worktrees.iter().map(|w| w.branch.as_str()).collect();

    // Header row (pinned by --header-lines=1) — print immediately
    println!("{DIM}  BRANCH{RESET}");

    // [new branch] option — print immediately
    println!("  {GREEN}[new branch]{RESET}");

    // Stream remote branches as we find them
    let output = Command::new("git")
        .args(["branch", "-r", "--format=%(refname:short)"])
        .output();

    if let Ok(o) = output {
        if o.status.success() {
            let stdout = String::from_utf8_lossy(&o.stdout);
            for line in stdout.lines() {
                let branch = line.strip_prefix("origin/").unwrap_or(line);
                if branch == "HEAD" || wt_branches.contains(&branch) {
                    continue;
                }
                println!("  {CYAN}{branch}{RESET}");
            }
        }
    }
}
