use crate::git;

/// Print worktree entries as TSV: branch\trel_path\tabs_path
pub fn run() {
    let worktrees = git::list_worktrees();
    let main_path = worktrees
        .iter()
        .find(|w| w.is_main)
        .map(|w| w.path.clone());

    for wt in &worktrees {
        let rel = if wt.is_main {
            ".".to_string()
        } else if let Some(ref main) = main_path {
            let main_str = main.to_string_lossy();
            let wt_str = wt.path.to_string_lossy();
            if let Some(suffix) = wt_str.strip_prefix(&format!("{main_str}/")) {
                suffix.to_string()
            } else {
                wt.path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| wt_str.to_string())
            }
        } else {
            wt.path.to_string_lossy().to_string()
        };

        println!("{}\t{}\t{}", wt.branch, rel, wt.path.display());
    }
}
