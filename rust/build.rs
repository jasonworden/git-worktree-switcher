use std::process::Command;

fn main() {
    // Embed git SHA so `wt-core --version` shows which commit it was built from
    let sha = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let dirty = Command::new("git")
        .args(["diff", "--quiet"])
        .status()
        .map(|s| !s.success())
        .unwrap_or(false);

    let suffix = if dirty { "-dirty" } else { "" };

    println!("cargo:rustc-env=WT_GIT_SHA={sha}{suffix}");
    // Rerun if git HEAD changes
    println!("cargo:rerun-if-changed=../.git/HEAD");
}
