# Unified `wt` Command — Design Spec

**Date:** 2026-04-07
**Status:** Draft
**Supersedes:** Current separate `wt` (picker) and `wt clean` implementations

## Summary

Merge `wt` and `wt clean` into a single unified worktree manager with three modes: **browse**, **uproot**, and **plant**. The unified view shows all worktrees instantly with local data, then progressively loads remote info without UI jank. Enforces a standard worktree path convention with per-repo overrides. Includes an opinionated settings bundle for power users.

## Goals

1. One command (`wt`) for all worktree management — switch, inspect, create, delete, bulk cleanup
2. Show worktrees as fast as possible (local data instant), enrich with remote data in background
3. No UI shifting — columns pre-allocated, single smooth reload when remote data arrives
4. Enforce a clean worktree directory convention by default
5. Opinionated mode for teams/power users who want guardrails

## Non-Goals

- Replacing git worktree internals (we wrap git, not replace it)
- Cross-repo overview (`wt canopy` — future work)
- Sync/update mode (`wt water` — future work)
- Custom TUI (ratatui) — fzf is sufficient for v1

---

## Architecture

### Pipeline

```
wt (zsh)
  ├─ calls wt-core unified --local    → instant TSV (local data)
  ├─ pipes into fzf --listen=PORT     → picker is live, user can interact
  ├─ background: wt-core unified --remote  → git fetch --prune + GH API
  └─ on complete: curl fzf reload with enriched TSV
```

### Separation of Concerns

- **Rust (`wt-core`)**: all git operations, GitHub API, data gathering, verdict logic
- **Zsh wrapper**: fzf lifecycle, `--listen` port management, `cd`, user prompts, mode switching
- **No interactive I/O in Rust**, no git ops in zsh (existing principle, maintained)

### Rust Core Changes

New `unified` subcommand replacing `picker`, `entries`, `clean-check`:

```
wt-core unified --local          # fast path: local git ops only
wt-core unified --remote         # slow path: fetch + GitHub API
wt-core unified --preview <path> # detail info for preview pane
```

Both `--local` and `--remote` output the same TSV schema. In `--local` mode, remote columns output `··` (placeholder). In `--remote` mode, all columns are filled.

Old subcommands (`picker`, `entries`, `clean-check`) are deprecated but kept for backward compatibility during transition.

### TSV Schema

```
branch \t rel_path \t abs_path \t tree_status \t ahead_count \t remote_status \t pr_status \t verdict \t is_main
```

| Column | Local | Remote | Values |
|--------|-------|--------|--------|
| `branch` | yes | — | branch name |
| `rel_path` | yes | — | relative path from main worktree |
| `abs_path` | yes | — | absolute path (hidden from display, used for actions) |
| `tree_status` | yes | — | `clean`, `dirty` |
| `ahead_count` | yes | — | integer (0 = `—`) |
| `remote_status` | no | yes | `origin ✓`, `gone`, `—`, `no remote` |
| `pr_status` | no | yes | `#N merged`, `#N open`, `no PR`, `—`, `no gh` |
| `verdict` | partial | yes | `pending` (local), `safe`, `keep`, `unsafe`, `pinned` (remote) |
| `is_main` | yes | — | `true` or `false` |

### No-Remote Handling

- Detect at startup: `git remote get-url origin`
- If no remote: status line shows "local only — no remote configured"
- Remote and PR columns show `—` permanently
- No fetch attempt, no retry

---

## Modes

### Browse Mode (default — `wt`)

The primary view. Shows all worktrees with progressive loading.

**Interaction:**
- Arrow keys to navigate, fuzzy search to filter
- `enter` (nothing selected) → `cd` to highlighted worktree
- `enter` (with selections) → open all selected in editor
- `tab` → toggle multi-select on highlighted item
- `ctrl-o` → open highlighted in `$WT_OPENER` (default: `code`)
- `ctrl-x` → delete highlighted worktree (confirmation prompt)
- `ctrl-u` → switch to uproot mode
- `ctrl-n` → switch to plant mode

**Preview pane** (fzf `--preview`): shows detail for highlighted worktree:
- Recent commits (last 5, `git log --oneline`)
- Changed files (`git diff --stat` against default branch)
- Stash count
- Last commit date

**Main worktree:** shown with `●` indicator, cleanup actions disabled.

### Uproot Mode (`wt uproot` or `wt clean` or `ctrl-u`)

Bulk removal of stale worktrees.

**On entry:**
- Header changes to uproot context with red indicator
- VERDICT column appears (or becomes prominent)
- "Safe" worktrees are pre-selected (tab-toggled on)
- Main worktree shown as grayed out with "pinned" verdict

**Verdict logic:**
- `safe` = remote branch gone OR PR merged, AND no unique commits ahead, AND clean tree
- `keep` = has unique commits ahead OR dirty tree, but remote gone/PR merged
- `unsafe` = dirty tree OR unique commits, remote still exists
- `pinned` = main worktree (never deletable)

**Interaction:**
- `tab` → toggle selection on highlighted
- `enter` → confirm removal of all selected worktrees
- `ctrl-b` → back to browse mode
- Confirmation prompt before deletion shows summary of what will be removed

**Branch cleanup:** controlled by `wt.opinionated.deleteBranch` or `--keep-branches` flag. When enabled, `git branch -D` runs for each uprooted worktree's branch (only if verdict is `safe`).

### Plant Mode (`wt plant` or `ctrl-n`)

Guided worktree creation wizard.

**On entry:**
- fzf list switches to show:
  - `[new branch]` option at top
  - Existing remote branches not yet checked out as worktrees
- Typing fuzzy-filters the branch list

**Flow — existing branch:**
1. Select a branch from the list
2. Preview shows: target path, base branch, recent commits on that branch
3. `enter` confirms → creates worktree at convention path
4. Auto-cd into new worktree (in opinionated mode)

**Flow — new branch:**
1. Select `[new branch]`
2. Prompt for branch name (with prefix enforcement if opinionated)
3. Preview shows: target path, base branch (default branch)
4. `enter` confirms → creates branch + worktree
5. Auto-cd into new worktree (in opinionated mode)

**Path determination:**
1. Check `git config wt.basedir` (per-repo override)
2. Check `WT_BASE_DIR` env var (global override)
3. Fallback: `<repo>/.worktrees/<branch>/`

---

## Column Layout

### Phase 1: Instant (local data)

```
  BRANCH          PATH                    TREE    AHEAD   REMOTE   PR
● main            .                       clean   —       ··       ··
  feat-auth       .worktrees/feat-auth    clean   2       ··       ··
  fix-nav         .worktrees/fix-nav      clean   —       ··       ··
  refactor-db     .worktrees/refactor-db  dirty   5       ··       ··
────────────────────────────────────────────────────────────────────────
⟳ Fetching remote info...     ctrl-u uproot · ctrl-n plant · enter cd
```

### Phase 2: After remote check

```
  BRANCH          PATH                    TREE    AHEAD   REMOTE     PR
● main            .                       clean   —       —          —
  feat-auth       .worktrees/feat-auth    clean   2       origin ✓   no PR
  fix-nav         .worktrees/fix-nav      clean   —       gone       #42 merged
  refactor-db     .worktrees/refactor-db  dirty   5       origin ✓   no PR
────────────────────────────────────────────────────────────────────────
✓ Remote checks complete      ctrl-u uproot · ctrl-n plant · enter cd
```

Columns are fixed-width, pre-allocated for longest expected values. The `··` → real value swap happens in a single fzf reload — no per-cell updates.

### Status Bar

Bottom line serves dual purpose:
1. **Loading state**: `⟳ Fetching remote info...` (yellow)
2. **Complete state**: `✓ Remote checks complete` (green) or `— local only` (dim)
3. **Mode indicator**: keybind hints change per mode
4. **Uproot mode**: `⚠ UPROOT MODE` (red) with uproot-specific keybinds

---

## Worktree Path Convention

### Default

```
~/code/my-project/                          ← main worktree
~/code/my-project/.worktrees/feat-auth/     ← worktree
~/code/my-project/.worktrees/fix-nav/       ← worktree
```

### Configuration

**Per-repo** (highest priority):
```
git config wt.basedir /custom/path
```

**Global** (env var fallback):
```
export WT_BASE_DIR=~/worktrees
# Result: ~/worktrees/<branch>/
```

**Default** (no config):
```
<main-worktree>/.worktrees/<branch>/
```

### Auto-Gitignore

On first worktree creation (`wt plant`), automatically add to `.gitignore` if not already present:
```
.worktrees/
.claude/worktrees/
```

- **Opinionated mode**: add silently
- **Non-opinionated mode**: prompt user before adding

The `.claude/worktrees/` entry covers Claude Code's worktree directory convention.

---

## Opinionated Mode

A pre-selected bundle of settings for power users and teams.

### Settings Bundle

| Setting | Config key | Opinionated default | Non-opinionated default |
|---------|-----------|--------------------|-----------------------|
| Main worktree guard | `wt.opinionated.mainGuard` | `true` — warn + redirect to plant | No guard |
| Worktree path convention | `wt.basedir` | `.worktrees/<branch>/` | Sibling dirs |
| Auto-gitignore | `wt.opinionated.autoGitignore` | `true` — add silently | Prompt |
| Delete branch on uproot | `wt.opinionated.deleteBranch` | `true` (if verdict is safe) | Ask each time |
| Auto-fetch on open | `wt.opinionated.autoFetch` | `true` — background fetch every `wt` invocation | Only in uproot mode |
| Branch naming prefix | `wt.opinionated.branchPrefix` | `true` — enforce `feat/`, `fix/`, `chore/` in plant | Freeform |
| Stale worktree warnings | `wt.opinionated.staleWarning` | `true` — highlight 2+ weeks untouched | No warnings |
| Auto-cd after plant | `wt.opinionated.autoCd` | `true` | Stay in current dir |

See [Configuration System](#configuration-system) for how to enable, override, and layer these settings.

---

## Configuration System

Layered configuration with committable team defaults and personal overrides.

### `.wt/` Directory (team-shared, committed)

```
.wt/                          ← committed to repo
  config                      ← TOML settings
  hooks/
    post-plant.sh             ← runs after wt plant
    post-enter.sh             ← runs after cd via wt
```

### Priority (highest to lowest)

1. `git config wt.*` — personal overrides (`.git/config`, not committed)
2. `.wt/config` — team-shared defaults (committed)
3. Environment variables (`WT_*`)
4. Built-in defaults

Any setting in `.wt/config` can be disabled personally: if team sets `opinionated = true`, a member can `git config wt.opinionated false` to opt out.

### `.wt/config` Format (TOML)

```toml
[wt]
opinionated = true
basedir = ".worktrees"

[wt.opinionated]
mainGuard = true
autoFetch = true
branchPrefix = true
staleWarning = true
autoCd = true
deleteBranch = true
autoGitignore = true
```

### Personal Overrides via `git config`

```bash
# Opt out of opinionated mode personally
git config wt.opinionated false

# Override a single setting
git config wt.opinionated.branchPrefix false

# Set a custom basedir
git config wt.basedir "/custom/path"
```

---

## Hooks

Two hook points, always available (not gated behind opinionated mode). Hooks live in `.wt/hooks/` for team sharing, with `git config` override for personal customization.

### Post-Plant Hook

Runs after creating a worktree.

**Team-shared** (`.wt/hooks/post-plant.sh`):
```bash
#!/bin/sh
npm install
cp .env.example .env
```

**Personal override** (`git config`):
```bash
git config wt.hook.post-plant "npm install && direnv allow"
```

**Execution:** runs in the new worktree directory. Stdout/stderr shown to user. Non-zero exit = warning (worktree still created). `git config` value takes priority over `.wt/hooks/` script.

### Post-Enter Hook

Runs after `cd`-ing into a worktree via `wt`.

**Team-shared** (`.wt/hooks/post-enter.sh`):
```bash
#!/bin/sh
nvm use
```

**Personal override** (`git config`):
```bash
git config wt.hook.post-enter "nvm use"
```

**Execution:** runs in the target worktree directory. Stdout shown to user. Non-zero exit = warning (cd still happens). `git config` value takes priority over `.wt/hooks/` script.

### Hook Environment

Both hooks receive environment variables:
- `WT_BRANCH` — branch name
- `WT_PATH` — absolute worktree path
- `WT_MAIN_PATH` — absolute main worktree path
- `WT_IS_NEW` — `true` for post-plant, `false` for post-enter

---

## Progressive Loading Implementation

### fzf `--listen` Pipeline

1. **Zsh starts fzf** with `--listen=localhost:$PORT` (random available port)
2. **Zsh pipes** output of `wt-core unified --local` as initial input
3. **Zsh backgrounds** `wt-core unified --remote` with output to a temp file
4. **On remote completion**: zsh reads temp file, sends `reload(...)` to fzf via HTTP
5. **Status line**: updated via `change-header(...)` action on reload

### fzf Version Requirement

`--listen` requires fzf 0.30+ (released March 2022). On older versions, fall back to showing local data only with a note to upgrade fzf for remote features.

### Mode Switching via fzf Bindings

```
--bind 'ctrl-u:change-header(...)+change-prompt(uproot> )+reload(...)'
--bind 'ctrl-n:change-header(...)+change-prompt(plant> )+reload(...)'
--bind 'ctrl-b:change-header(...)+change-prompt(> )+reload(...)'
```

Each mode switch triggers a reload with mode-appropriate data (e.g., uproot adds verdict column, plant shows available branches).

---

## Migration Path

### Backward Compatibility

- `wt clean` continues to work as an alias for `wt uproot`
- Old Rust subcommands (`picker`, `entries`, `clean-check`) remain functional but deprecated
- Existing env vars (`WT_OPENER`, `WT_CLEAN_KEEP_BRANCHES`) continue to work

### New Env Vars

| Variable | Purpose | Default |
|----------|---------|---------|
| `WT_BASE_DIR` | Global worktree base directory | (unset — uses `.worktrees/`) |
| `WT_OPINIONATED` | Enable opinionated mode | `0` |
| `WT_OPENER` | Editor command (existing) | `code` |
| `WT_CLEAN_KEEP_BRANCHES` | Keep local branches on uproot (existing) | `0` |

---

## Future Work

- **`wt water`**: sync/update mode — pull/rebase across worktrees
- **`wt canopy`**: cross-repo worktree overview
- **`wt transplant`**: move/rename worktree paths
- **Custom branch prefix list**: configurable prefix set instead of hardcoded `feat/fix/chore`
- **Per-worktree hooks**: different post-enter commands per branch pattern
