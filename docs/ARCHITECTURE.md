# Architecture

## System overview

```
wt (zsh function)
  |
  +-- _wt_picker (fzf lifecycle, mode switching, cd, hooks)
  |     |
  |     +-- wt-core unified --local --format=browse   (instant, stdin to fzf)
  |     +-- wt-core unified --remote --format=browse  (background, curl POST to fzf --listen)
  |     +-- wt-core unified --preview <path>          (fzf preview pane)
  |     +-- wt-core unified --branches                (plant mode branch list)
  |
  +-- _wt_handle_plant (worktree creation flow)
  +-- _wt_handle_uproot (bulk deletion flow)
  +-- _wt_run_hook (post-plant, post-enter hooks)
```

## Separation of concerns

| Layer | Responsibility | No-go |
|-------|---------------|-------|
| **Rust (`wt-core`)** | Git operations, GitHub API, data gathering, ANSI formatting, verdict logic, config | No interactive I/O, no `cd` |
| **Zsh (`plugin.zsh`)** | fzf lifecycle, `--listen` port, `cd` into worktrees, user prompts, mode switching | No git operations |

## Rust modules (`rust/src/`)

| Module | Purpose | Key functions |
|--------|---------|--------------|
| `main.rs` | CLI entry point (clap). Dispatches subcommands | `Commands` enum |
| `unified.rs` | **Core module.** Progressive loading, column formatting, verdicts | `gather_local()`, `gather_remote()`, `run_branches()`, `run_preview()` |
| `git.rs` | Git primitives: worktree list parsing, dirty check, branch ops | `list_worktrees()`, `has_changes()`, `remote_branch_gone()` |
| `config.rs` | Layered config: `.wt/config` TOML + `git config wt.*` + env vars | `load() -> Config` |
| `clean.rs` | GitHub PR merge detection, legacy clean-check | `fetch_merged_prs()` |
| `entries.rs` | Legacy worktree listing (used by tab completion) | `run()`, `worktree_rel()` |
| `add.rs` | Worktree creation with path convention | `run(branch) -> Result` |
| `delete.rs` | Worktree removal | `run(path) -> Result` |

## Data flow: progressive loading

```
1. wt-core unified --local          Fast path: single `git worktree list` call
   |                                 Output: TSV with placeholder dots (··) for remote columns
   v
2. fzf --listen=$PORT < local.txt   User sees worktrees instantly
   |
3. wt-core unified --remote         Slow path: git fetch + GitHub API (background)
   |                                 Output: TSV with all columns filled
   v
4. curl POST localhost:$PORT         "reload(cat remote.txt)+change-header(Ready)+clear-screen"
   |                                 +clear-screen forces terminal redraw (fzf rendering bug workaround)
   v
5. fzf reloads list                  User sees enriched data, no UI freeze
```

## TSV schema (10 columns)

```
branch \t rel_path \t abs_path \t tree \t ahead \t remote \t pr \t verdict \t is_main \t stale
```

| Column | Local mode | Remote mode | Example values |
|--------|-----------|-------------|----------------|
| branch | branch name | — | `feat-auth` |
| rel_path | relative to main worktree | — | `.worktrees/feat-auth` |
| abs_path | absolute path | — | `/Users/j/code/repo/.worktrees/feat-auth` |
| tree | `··` (placeholder) | `clean` / `dirty` | |
| ahead | `··` (placeholder) | commit count or `—` | `3`, `—` |
| remote | `··` (placeholder) | `origin ✓` / `gone` / `no remote` | |
| pr | `··` (placeholder) | `#42 merged` / `no PR` / `no gh` | |
| verdict | `pending` / `pinned` | `safe` / `keep` / `unsafe` / `pinned` | |
| is_main | `true` / `false` | — | |
| stale | `false` | `true` if last commit > 2 weeks | |

## Verdict logic (uproot mode)

| Verdict | Condition | Meaning |
|---------|-----------|---------|
| `safe` | (remote gone OR PR merged) AND clean AND no unique commits | Safe to delete |
| `keep` | Has unique commits or dirty tree, but remote signal exists | Probably done, but has unsaved work |
| `unsafe` | Dirty tree or unique commits, remote still exists | Active development |
| `pinned` | Main worktree | Never deletable |

## Three modes

### Browse (default)

Columns: indicator, BRANCH, PATH, TREE, +COMMITS, REMOTE, PR. Main worktree marked with green `●`.

### Uproot

Same columns + VERDICT. Sorted by verdict (pinned first, then safe, keep, unsafe). Multi-select enabled for bulk deletion.

### Plant

Simple branch picker showing remote branches not yet checked out. `[new branch]` option at top. `__NEW__` tab-delimited marker for machine-parseable detection.

## Config system

Priority (highest to lowest):
1. `git config wt.*` (personal, not committed)
2. `.wt/config` TOML (team-shared, committed)
3. Environment variables (`WT_*`)
4. Built-in defaults

Key settings: `wt.opinionated` (boolean bundle), `wt.basedir`, `wt.opinionated.mainGuard`, `wt.opinionated.branchPrefix`, `wt.opinionated.staleWarning`, `wt.opinionated.autoCd`, `wt.opinionated.deleteBranch`.

## Hooks

| Hook | Trigger | Env vars |
|------|---------|----------|
| `post-plant` | After worktree creation | `WT_BRANCH`, `WT_PATH`, `WT_MAIN_PATH`, `WT_IS_NEW=true` |
| `post-enter` | After cd via `wt` | `WT_BRANCH`, `WT_PATH`, `WT_MAIN_PATH`, `WT_IS_NEW=false` |

Sources: `.wt/hooks/<name>.sh` (team) or `git config wt.hook.<name>` (personal override).

## Legacy subcommands (deprecated, kept for compatibility)

`wt-core picker`, `wt-core entries`, `wt-core clean-check`, `wt-core quick-status`, `wt-core gh-available`, `wt-core completions`. The `entries` subcommand is still used by tab completion. All others are superseded by `wt-core unified`.

## Known limitations (fzf-based)

- Header bar disappears after `--listen` HTTP POST reload (workaround: `+clear-screen`)
- No ANSI in headers sent via curl POST (use plain text only)
- Mode switching uses `become()` which spawns new fzf processes
- Plant mode is a separate fzf invocation with its own bindings
- No timer/periodic events in fzf — progressive loading requires HTTP POST

These are architectural limitations of fzf. A future ratatui rewrite would resolve all of them while reusing the entire Rust data layer (`unified.rs`, `git.rs`, `config.rs`, `clean.rs`).

## Worktree path convention

```
<main-worktree>/.worktrees/<branch>/    (default)
<wt.basedir>/<branch>/                  (per-repo override via git config)
$WT_BASE_DIR/<branch>/                  (global override via env var)
```

## Distribution

- Homebrew: `brew install jasonworden/tap/wt-core`
- Zsh plugin: source `git-worktree-switcher.plugin.zsh` (auto-discovers `wt-core` in PATH)
