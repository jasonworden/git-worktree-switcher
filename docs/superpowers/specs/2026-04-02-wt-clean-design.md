# Design: `wt clean` — Worktree Cleanup Helper

## Problem

Worktrees accumulate over time. Branches get merged, PRs get closed, but the
local worktrees stick around. There's no easy way to see which worktrees are
stale and safe to remove.

## Solution

Two additions to the existing `wt` plugin:

1. **`wt clean`** — A dedicated cleanup subcommand that checks each worktree
   against multiple staleness signals, makes an opinionated recommendation, shows
   the evidence, and lets the user batch-delete via fzf multi-select.

2. **Main picker staleness hints** — Lightweight indicators in the existing `wt`
   fzf picker so stale worktrees are visible during normal use.

## Staleness Signals

Checked in order of cost:

| Signal | Method | Cost | Used in |
|--------|--------|------|---------|
| Uncommitted changes | `git -C <wt> status --porcelain` | Local | Both |
| Unique local commits | `git log <default-branch>..<branch> --oneline` | Local | Both |
| Remote branch gone | Check `refs/remotes/origin/<branch>` exists | Local | Both |
| PR merged | `gh pr list --head <branch> --state merged` | Network | `wt clean` only |

### Fetching strategy

- **Main picker**: No fetch. Uses whatever remote state is already local. May be
  stale, but keeps the picker instant. This is a hint, not a verdict.
- **`wt clean`**: Runs `git fetch --prune` at the start to freshen remote
  tracking refs before checking signals. Users expect this command to take a
  moment and be accurate.

## Verdict Logic

A worktree is **"safe to delete"** when ALL of:
- Remote branch is gone OR PR is merged
- No unique local commits ahead of main
- Working directory is clean (no staged/unstaged/untracked files)

Any failing condition becomes a visible warning on that worktree.

The main worktree is always excluded from cleanup.

## `wt clean` UX Flow

### 1. Pre-flight: gh check

Before running checks, verify GitHub CLI availability:

1. If `gh` is not installed: print `"tip: brew install gh for PR merge detection"`
2. If installed but not authenticated for this repo's host: print
   `"tip: run 'gh auth login' to enable PR status checks"`
3. Continue either way — skip PR checks if gh is unavailable/unauthed.

### 2. Gather signals

Run `git fetch --prune`, then collect all four signals for each non-main
worktree.

### 3. fzf multi-select picker

Open fzf with `--multi` showing each worktree with its verdict:

- Safe worktrees show clean:
  ```
  ✓ feature-xyz         PR #42 merged · remote gone · clean
  ```
- Concerning worktrees show warnings:
  ```
  ⚠ experiment-abc      2 commits ahead of main · uncommitted changes
  ```

Evidence is always shown for worktrees with warnings. For safe worktrees, the
brief summary line (e.g., "PR #42 merged") is sufficient — no need to
elaborate when there are zero concerns.

User multi-selects with tab, hits enter.

### 4. Confirmation

Print a summary of what will be removed:

```
Will delete 3 worktrees (and local branches):
  - feature-xyz
  - bugfix-123
  - old-experiment

Proceed? [y/N]
```

### 5. Batch delete

Remove each selected worktree and its local branch. If the user is currently
cd'd into a worktree being deleted, move them to the main worktree first
(existing `_wt_delete` behavior).

### Branch deletion behavior

By default, `wt clean` deletes both the worktree and its local branch.

- `--keep-branches` flag: only remove worktrees, leave local branches intact.
- `WT_CLEAN_KEEP_BRANCHES=1` env var: same as `--keep-branches` but persistent.
  For users who always want this behavior.

## Main Picker Enhancement

Add a small indicator to each worktree line in the existing `wt` picker:

- `✓` — remote branch gone AND no unique commits AND clean working dir
- `⚠` — any local concern (unique commits, uncommitted changes)
- (nothing) — can't determine (remote branch still exists, unknown PR status)

These use **only local checks** (no fetch, no network). They are hints based on
the last fetch, not authoritative verdicts.

### Keybinding

Add `ctrl-g:clean` to the main picker header to launch `wt clean` directly:

```
enter:switch | ctrl-a:add | ctrl-o:open | ctrl-x:delete | ctrl-g:clean
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WT_OPENER` | `code` | Editor command (existing) |
| `WT_CLEAN_KEEP_BRANCHES` | unset | Set to `1` to keep local branches when cleaning |

## Dependencies

- **Required**: git, fzf (existing)
- **Optional**: gh (GitHub CLI) — enables PR merge detection. Gracefully
  degrades without it, with a nudge to install/auth.
