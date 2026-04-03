# Rust Migration — Implementation Plan

Spec: `docs/superpowers/specs/2026-04-03-rust-migration-design.md`

## Chunks (designed for parallel subagent execution)

### Chunk 1: Rust scaffold + git helpers + entries command
**Files:** `rust/Cargo.toml`, `rust/src/main.rs`, `rust/src/git.rs`, `rust/src/entries.rs`

- `cargo init` in `rust/` directory
- Add clap dependency with derive feature
- `git.rs`: helpers to run `git worktree list --porcelain`, parse into `Worktree` struct (path, branch, is_main)
- `entries.rs`: print TSV (branch, rel_path, abs_path) — port of `_wt_entries()`
- `main.rs`: clap CLI with `entries` subcommand + `main-worktree` + `default-branch`
- Unit tests for porcelain parsing

### Chunk 2: add + delete subcommands
**Files:** `rust/src/add.rs`, `rust/src/delete.rs`, update `rust/src/main.rs`

- `add.rs`: takes branch name, computes sibling path, checks if branch exists, runs `git worktree add [-b] ...`, prints target path
- `delete.rs`: takes path, runs `git worktree remove <path>`
- Wire into clap CLI
- Tests

### Chunk 3: staleness + clean-check subcommand
**Files:** `rust/src/clean.rs`, update `rust/src/main.rs`

- `has_changes(path)`: run `git -C <path> status --porcelain`, check non-empty
- `unique_commits(branch, default)`: run `git log --oneline default..branch | wc -l`
- `remote_branch_gone(branch)`: run `git show-ref --verify refs/remotes/origin/<branch>`
- `gh_available()`: check `gh auth token`
- `fetch_merged_prs()`: GraphQL query via `ureq`, parse with serde
- `quick-status` subcommand: local-only check, output safe/warn/empty
- `clean-check` subcommand: full pipeline (fetch + PR query + all verdicts), output TSV
- `gh-available` subcommand: exit code only
- Tests for verdict logic

### Chunk 4: Thin zsh wrapper
**Files:** `git-worktree-switcher.plugin.zsh` (rewrite)

- Replace all `_wt_*` data functions with `wt-core` calls
- Keep `wt()`, `_wt()`, fzf invocation, cd, prompts, colors in zsh
- Preserve exact same UX (keybindings, fzf header, ANSI colors)
- Ensure `WT_OPENER` and `WT_CLEAN_KEEP_BRANCHES` still work

### Chunk 5: Update tests + CI
**Files:** `spec/*`, `.github/workflows/test.yml`

- Update ShellSpec tests to work with the binary (build first, put on PATH)
- Add `cargo test` step to CI
- Add Rust toolchain setup to CI
- Update spec_helper.sh to build/locate wt-core binary

### Chunk 6: Homebrew formula + README
**Files:** `Formula/wt-core.rb`, `README.md`

- Write Homebrew formula
- Update README with new installation (brew install + plugin manager)
- Document that `wt-core` binary is required

## Execution Order

Chunks 1-3 are independent Rust work (can parallelize 1+2, then 3 needs git.rs from 1).
Chunk 4 depends on 1-3 (needs the binary interface).
Chunk 5 depends on 4.
Chunk 6 depends on all.

Practical order: 1 → 2+3 parallel → 4 → 5 → 6
