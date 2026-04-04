use std::path::PathBuf;

use crate::clean;
use crate::git;

/// Relative path segment for display (`.` for main worktree).
pub fn worktree_rel(wt: &git::Worktree, main_path: Option<&PathBuf>) -> String {
    if wt.is_main {
        return ".".to_string();
    }
    if let Some(main) = main_path {
        let main_str = main.to_string_lossy();
        let wt_str = wt.path.to_string_lossy();
        if let Some(suffix) = wt_str.strip_prefix(&format!("{main_str}/")) {
            return suffix.to_string();
        }
        return wt
            .path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| wt_str.to_string());
    }
    wt.path.to_string_lossy().to_string()
}

/// Print worktrees as TSV: branch\trel_path\tabs_path
pub fn run() {
    let worktrees = git::list_worktrees();
    let main_path = worktrees
        .iter()
        .find(|w| w.is_main)
        .map(|w| w.path.clone());

    for wt in &worktrees {
        let rel = worktree_rel(wt, main_path.as_ref());
        println!("{}\t{}\t{}", wt.branch, rel, wt.path.display());
    }
}

/// TSV for the zsh fzf picker: branch, rel, abs, staleness (`safe` | `warn` | empty).
/// One process — avoids N× `quick-status` subprocess cost.
pub fn run_picker() {
    let worktrees = git::list_worktrees();
    let main_path = worktrees
        .iter()
        .find(|w| w.is_main)
        .map(|w| w.path.clone());
    let default_branch = git::default_branch().unwrap_or_else(|| "main".to_string());

    for wt in &worktrees {
        let rel = worktree_rel(wt, main_path.as_ref());
        let staleness = if wt.is_main {
            ""
        } else if let Some(s) = clean::quick_status_label(&wt.branch, &wt.path, &default_branch) {
            s
        } else {
            ""
        };
        println!("{}\t{}\t{}\t{}", wt.branch, rel, wt.path.display(), staleness);
    }
}
