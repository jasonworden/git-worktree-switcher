use std::path::{Path, PathBuf};
use std::process::Command;

/// All wt settings, resolved from layered sources.
#[derive(Debug, Clone)]
pub struct Config {
    pub opinionated: bool,
    pub basedir: Option<String>,
    pub main_guard: bool,
    pub auto_gitignore: bool,
    pub delete_branch: bool,
    pub auto_fetch: bool,
    pub branch_prefix: bool,
    pub stale_warning: bool,
    pub auto_cd: bool,
    pub hook_post_plant: Option<String>,
    pub hook_post_enter: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            opinionated: false,
            basedir: None,
            main_guard: false,
            auto_gitignore: false,
            delete_branch: false,
            auto_fetch: false,
            branch_prefix: false,
            stale_warning: false,
            auto_cd: false,
            hook_post_plant: None,
            hook_post_enter: None,
        }
    }
}

/// TOML schema for .wt/config
#[derive(Debug, Default, serde::Deserialize)]
struct TomlFile {
    wt: Option<TomlWt>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct TomlWt {
    opinionated: Option<bool>,
    basedir: Option<String>,
    #[serde(default)]
    opinionated_settings: Option<TomlOpinionated>,
    hook: Option<TomlHook>,
}

// Supports both [wt.opinionated] (table) and wt.opinionated (bool).
// The TOML key "opinionated" as bool lives in TomlWt::opinionated.
// Sub-settings live under [wt.opinionated_settings] mapped from [wt.opinionated.*] keys.
// We handle this by trying to parse the file with a flexible approach.

#[derive(Debug, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct TomlOpinionated {
    main_guard: Option<bool>,
    auto_gitignore: Option<bool>,
    delete_branch: Option<bool>,
    auto_fetch: Option<bool>,
    branch_prefix: Option<bool>,
    stale_warning: Option<bool>,
    auto_cd: Option<bool>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
struct TomlHook {
    post_plant: Option<String>,
    post_enter: Option<String>,
}

/// Read a git config key, returning None if unset or on error.
fn git_config(key: &str) -> Option<String> {
    Command::new("git")
        .args(["config", "--get", key])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

fn git_config_bool(key: &str) -> Option<bool> {
    git_config(key).map(|v| matches!(v.as_str(), "true" | "1" | "yes"))
}

/// Parse .wt/config TOML if it exists in the repo root.
fn read_wt_config(repo_root: &Path) -> Option<TomlFile> {
    let config_path = repo_root.join(".wt").join("config");
    let content = std::fs::read_to_string(config_path).ok()?;
    toml::from_str(&content).ok()
}

/// Find the repository root (where .git lives).
fn repo_root() -> Option<PathBuf> {
    Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim().to_string()))
}

/// Load config with full layering: git config > .wt/config > env vars > defaults.
pub fn load() -> Config {
    let mut cfg = Config::default();

    // Layer 4: env vars
    if let Ok(v) = std::env::var("WT_OPINIONATED") {
        cfg.opinionated = matches!(v.as_str(), "1" | "true" | "yes");
    }
    if let Ok(v) = std::env::var("WT_BASE_DIR") {
        if !v.is_empty() {
            cfg.basedir = Some(v);
        }
    }

    // Layer 3: .wt/config (TOML)
    if let Some(root) = repo_root() {
        if let Some(toml) = read_wt_config(&root) {
            if let Some(wt) = toml.wt {
                if let Some(v) = wt.opinionated {
                    cfg.opinionated = v;
                }
                if let Some(v) = wt.basedir {
                    cfg.basedir = Some(v);
                }
                if let Some(op) = wt.opinionated_settings {
                    apply_opinionated_settings(&mut cfg, &op);
                }
                if let Some(hook) = wt.hook {
                    cfg.hook_post_plant = hook.post_plant;
                    cfg.hook_post_enter = hook.post_enter;
                }
            }
        }
    }

    // Apply opinionated defaults if bundle is on (before git config overrides)
    if cfg.opinionated {
        apply_opinionated_defaults(&mut cfg);
    }

    // Layer 2: git config (highest priority)
    if let Some(v) = git_config_bool("wt.opinionated") {
        cfg.opinionated = v;
        if v {
            apply_opinionated_defaults(&mut cfg);
        }
    }
    if let Some(v) = git_config("wt.basedir") {
        cfg.basedir = Some(v);
    }
    if let Some(v) = git_config_bool("wt.opinionated.mainGuard") {
        cfg.main_guard = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.autoGitignore") {
        cfg.auto_gitignore = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.deleteBranch") {
        cfg.delete_branch = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.autoFetch") {
        cfg.auto_fetch = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.branchPrefix") {
        cfg.branch_prefix = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.staleWarning") {
        cfg.stale_warning = v;
    }
    if let Some(v) = git_config_bool("wt.opinionated.autoCd") {
        cfg.auto_cd = v;
    }
    if let Some(v) = git_config("wt.hook.post-plant") {
        cfg.hook_post_plant = Some(v);
    }
    if let Some(v) = git_config("wt.hook.post-enter") {
        cfg.hook_post_enter = Some(v);
    }

    cfg
}

fn apply_opinionated_settings(cfg: &mut Config, op: &TomlOpinionated) {
    if let Some(v) = op.main_guard {
        cfg.main_guard = v;
    }
    if let Some(v) = op.auto_gitignore {
        cfg.auto_gitignore = v;
    }
    if let Some(v) = op.delete_branch {
        cfg.delete_branch = v;
    }
    if let Some(v) = op.auto_fetch {
        cfg.auto_fetch = v;
    }
    if let Some(v) = op.branch_prefix {
        cfg.branch_prefix = v;
    }
    if let Some(v) = op.stale_warning {
        cfg.stale_warning = v;
    }
    if let Some(v) = op.auto_cd {
        cfg.auto_cd = v;
    }
}

fn apply_opinionated_defaults(cfg: &mut Config) {
    cfg.main_guard = true;
    cfg.auto_gitignore = true;
    cfg.delete_branch = true;
    cfg.auto_fetch = true;
    cfg.branch_prefix = true;
    cfg.stale_warning = true;
    cfg.auto_cd = true;
    if cfg.basedir.is_none() {
        cfg.basedir = Some(".worktrees".to_string());
    }
}

/// Resolve the worktree base directory for a given main worktree path.
/// Returns the absolute path where new worktrees should be created.
pub fn resolve_basedir(cfg: &Config, main_wt: &Path) -> PathBuf {
    match &cfg.basedir {
        Some(dir) if Path::new(dir).is_absolute() => PathBuf::from(dir),
        Some(dir) => main_wt.join(dir),
        None => main_wt.parent().unwrap_or(main_wt).to_path_buf(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_non_opinionated() {
        let cfg = Config::default();
        assert!(!cfg.opinionated);
        assert!(!cfg.main_guard);
        assert!(cfg.basedir.is_none());
    }

    #[test]
    fn opinionated_defaults_set_all_flags() {
        let mut cfg = Config::default();
        apply_opinionated_defaults(&mut cfg);
        assert!(cfg.main_guard);
        assert!(cfg.auto_gitignore);
        assert!(cfg.delete_branch);
        assert!(cfg.auto_fetch);
        assert!(cfg.branch_prefix);
        assert!(cfg.stale_warning);
        assert!(cfg.auto_cd);
        assert_eq!(cfg.basedir.as_deref(), Some(".worktrees"));
    }

    #[test]
    fn resolve_basedir_relative() {
        let cfg = Config {
            basedir: Some(".worktrees".to_string()),
            ..Default::default()
        };
        let main_wt = Path::new("/home/user/project");
        assert_eq!(
            resolve_basedir(&cfg, main_wt),
            PathBuf::from("/home/user/project/.worktrees")
        );
    }

    #[test]
    fn resolve_basedir_absolute() {
        let cfg = Config {
            basedir: Some("/custom/path".to_string()),
            ..Default::default()
        };
        let main_wt = Path::new("/home/user/project");
        assert_eq!(
            resolve_basedir(&cfg, main_wt),
            PathBuf::from("/custom/path")
        );
    }

    #[test]
    fn resolve_basedir_none_uses_parent() {
        let cfg = Config::default();
        let main_wt = Path::new("/home/user/project");
        assert_eq!(
            resolve_basedir(&cfg, main_wt),
            PathBuf::from("/home/user")
        );
    }

    #[test]
    fn parse_toml_config() {
        let toml_str = r#"
[wt]
opinionated = true
basedir = ".worktrees"

[wt.hook]
post-plant = "npm install"
post-enter = "nvm use"
"#;
        let parsed: TomlFile = toml::from_str(toml_str).unwrap();
        let wt = parsed.wt.unwrap();
        assert_eq!(wt.opinionated, Some(true));
        assert_eq!(wt.basedir.as_deref(), Some(".worktrees"));
        let hook = wt.hook.unwrap();
        assert_eq!(hook.post_plant.as_deref(), Some("npm install"));
        assert_eq!(hook.post_enter.as_deref(), Some("nvm use"));
    }
}
