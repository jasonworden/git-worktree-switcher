# Unified `wt` Command — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Merge wt/wt clean into one unified command with browse, uproot, plant modes and progressive loading.

**Architecture:** fzf --listen + reload pipeline. New `wt-core unified` Rust subcommand. Thin zsh wrapper manages fzf lifecycle and mode switching.

**Tech Stack:** Rust (clap, serde_json, ureq), zsh, fzf 0.30+

---

## Task 1: Config module in Rust

**Files:**
- Create: `rust/src/config.rs`
- Modify: `rust/src/main.rs` (add mod)

Reads layered config: git config wt.* > .wt/config (TOML) > env vars > defaults. Exposes `Config` struct with all settings.

---

## Task 2: Unified --local subcommand

**Files:**
- Create: `rust/src/unified.rs`
- Modify: `rust/src/main.rs` (add Unified command)

New `wt-core unified --local` outputs TSV with 9 columns. Local-only: branch, rel_path, abs_path, tree_status, ahead_count, placeholders for remote/pr/verdict, is_main.

---

## Task 3: Unified --remote subcommand

**Files:**
- Modify: `rust/src/unified.rs`

`wt-core unified --remote` does git fetch --prune + GH API, outputs same TSV schema with all columns filled. Reuses existing clean.rs logic.

---

## Task 4: Unified --preview subcommand

**Files:**
- Modify: `rust/src/unified.rs`

`wt-core unified --preview <path>` outputs recent commits, diff stat, stash count for a single worktree.

---

## Task 5: Unified --branches subcommand

**Files:**
- Modify: `rust/src/unified.rs`

`wt-core unified --branches` lists remote branches not yet checked out as worktrees (for plant mode).

---

## Task 6: Config-aware add (path convention)

**Files:**
- Modify: `rust/src/add.rs`
- Modify: `rust/src/config.rs`

`wt-core add` uses config.basedir to determine worktree path. Default: `.worktrees/<branch>/`. Auto-adds .worktrees/ and .claude/worktrees/ to .gitignore.

---

## Task 7: Zsh browse mode with fzf --listen

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Rewrite `wt()` to use fzf --listen. Pipes `unified --local` as initial data, backgrounds `unified --remote`, reloads fzf on completion. Preview pane via `unified --preview`.

---

## Task 8: Zsh mode switching (slash commands, alt-N, ctrl-])

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Implement three mode-switching methods in fzf bindings. Header/prompt changes per mode.

---

## Task 9: Zsh uproot mode

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Uproot mode: shows verdict column, pre-selects safe items, enter confirms bulk deletion. `wt uproot` and `wt clean` as CLI aliases.

---

## Task 10: Zsh plant mode

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Plant mode: shows branches list from `unified --branches`, preview shows target path, enter creates worktree. `wt plant` as CLI alias.

---

## Task 11: Hooks (post-plant, post-enter)

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Run .wt/hooks/post-plant.sh or git config wt.hook.post-plant after creating worktree. Same for post-enter after cd.

---

## Task 12: Opinionated mode

**Files:**
- Modify: `rust/src/config.rs`
- Modify: `git-worktree-switcher.plugin.zsh`

Main worktree guard, branch prefix enforcement, stale warnings, auto-fetch, auto-cd. All togglable.

---

## Task 13: Tests and backward compat

**Files:**
- Create: `spec/wt_unified_spec.sh`
- Modify: `spec/spec_helper.sh`
- Rust unit tests in each module

Test unified TSV output, config layering, mode switching, backward compat (old subcommands still work).

---

## Task 14: Tab completion and help text updates

**Files:**
- Modify: `git-worktree-switcher.plugin.zsh`

Update `_wt` completion to include uproot/plant. Update --help text.
