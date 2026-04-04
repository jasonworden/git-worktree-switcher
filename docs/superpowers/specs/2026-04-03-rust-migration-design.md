# Rust Migration Design: git-worktree-switcher

## Goal

Rewrite the core logic of `git-worktree-switcher` in Rust, distributed via Homebrew, with a thin zsh plugin wrapper that delegates to the compiled binary. The zsh layer handles only what requires shell context: `cd`, `fzf` invocation, and tab completion.

## Architecture

```
┌─────────────────────┐     ┌──────────────────────────────┐
│  zsh plugin (thin)  │────▶│  wt-core (Rust binary)       │
│                     │     │                              │
│  - cd into dirs     │     │  - entries: parse worktrees   │
│  - fzf invocation   │     │  - add: create worktree      │
│  - tab completion   │     │  - delete: remove worktree   │
│  - user prompts     │     │  - clean-check: staleness    │
│  - keybinding logic │     │  - main-worktree: path       │
└─────────────────────┘     │  - default-branch: name      │
                            │  - quick-status: per-wt      │
                            │  - completions: branch list  │
                            └──────────────────────────────┘
```

## Rust Binary: `wt-core`

### Subcommands

| Subcommand | Output | Purpose |
|---|---|---|
| `wt-core entries` | TSV: `branch\trel_path\tabs_path` per line | List all worktrees |
| `wt-core main-worktree` | Single line: absolute path | Main worktree path |
| `wt-core default-branch` | Single line: branch name | Main worktree's branch |
| `wt-core add <branch>` | Prints created path on success | Create worktree + branch |
| `wt-core delete <path>` | Exit code only | Remove worktree by path |
| `wt-core quick-status <branch> <path> [default-branch]` | `safe`, `warn`, or empty | Fast local staleness check |
| `wt-core clean-check [--gh]` | TSV: `verdict\tbranch\tpath\tevidence` per line | Full staleness analysis |
| `wt-core completions` | Newline-separated branch names | For tab completion |
| `wt-core gh-available` | Exit 0 if gh installed+authed, 1 otherwise | Check gh CLI availability |

### Key Design Decisions

1. **No interactive I/O in the binary.** All prompts, fzf, and `cd` stay in zsh.
2. **TSV output** matches the existing format so the zsh wrapper migration is minimal.
3. **`clean-check` does the full pipeline**: fetch, PR batch query, signal gathering — outputs all verdicts at once.
4. **`add` does NOT `cd`** — it prints the target path, zsh wrapper does the `cd`.
5. **`delete` does NOT relocate** — zsh wrapper checks `$PWD` and relocates if needed.

### Crate Dependencies

- `clap` — CLI argument parsing
- `serde` / `serde_json` — JSON parsing for GraphQL responses
- `ureq` — HTTP client for GitHub API (no async needed, keeps binary small)

### Error Handling

- Errors go to stderr, structured output to stdout
- Non-zero exit codes for failures
- Graceful fallback when `gh` unavailable (just skip PR data)

## Zsh Plugin (Thin Wrapper)

The new `git-worktree-switcher.plugin.zsh` will:

1. Locate the `wt-core` binary (via `$PATH`, installed by Homebrew)
2. Delegate data operations to `wt-core` subcommands
3. Keep `cd`, `fzf`, prompts, and `compdef` in zsh

### What stays in zsh

- `wt()` main function: subcommand dispatch, `cd`, fzf picker, keybinding actions
- `_wt()` completion function
- All user prompts (`read -q`, `printf "Open in...?"`)
- `WT_OPENER` / `WT_CLEAN_KEEP_BRANCHES` env var handling
- fzf formatting and invocation (ANSI colors, column alignment)

### What moves to Rust

- `_wt_entries()` → `wt-core entries`
- `_wt_main_worktree()` → `wt-core main-worktree`
- `_wt_default_branch()` → `wt-core default-branch`
- `_wt_has_changes()` → folded into `quick-status` and `clean-check`
- `_wt_unique_commits()` → folded into `quick-status` and `clean-check`
- `_wt_remote_branch_gone()` → folded into `quick-status` and `clean-check`
- `_wt_gh_available()` → `wt-core gh-available`
- `_wt_pr_merged()` → folded into `clean-check`
- `_wt_fetch_merged_prs()` → folded into `clean-check`
- `_wt_check_worktree()` → folded into `clean-check`
- `_wt_quick_status()` → `wt-core quick-status`
- `_wt_add()` (git operations) → `wt-core add`
- `_wt_delete()` (git operations) → `wt-core delete`

## Homebrew Distribution

### Formula

```ruby
class WtCore < Formula
  desc "Fast git worktree manager (core binary)"
  homepage "https://github.com/jasonworden/git-worktree-switcher"
  url "https://github.com/jasonworden/git-worktree-switcher/archive/refs/tags/v{version}.tar.gz"
  license "MIT"

  depends_on "rust" => :build

  def install
    cd "rust" do
      system "cargo", "install", *std_cargo_args
    end
  end

  test do
    assert_match "Usage", shell_output("#{bin}/wt-core --help")
  end
end
```

### Tap

Use existing GitHub repo. Formula lives in `Formula/wt-core.rb` or in a separate `homebrew-tap` repo. Start with in-repo formula for simplicity.

## Testing Strategy

### Rust Tests

- Unit tests for each subcommand's core logic (parsing, staleness verdicts)
- Integration tests that create real git repos (same pattern as ShellSpec tests)
- `cargo test` in CI

### Shell Tests (ShellSpec)

- Existing tests adapted to call `wt-core` binary instead of shell functions
- New integration tests verifying the zsh wrapper + binary work together
- Keep same test structure: `spec/` directory, same helpers

### CI

- Add Rust build + test job to `.github/workflows/test.yml`
- Keep existing ShellSpec job, adjusted for the new wrapper

## File Structure

```
rust/
  Cargo.toml
  src/
    main.rs          # clap CLI entry point
    entries.rs       # worktree listing
    add.rs           # worktree creation
    delete.rs        # worktree removal
    clean.rs         # staleness checking + GitHub API
    git.rs           # shared git helpers
Formula/
  wt-core.rb        # Homebrew formula
git-worktree-switcher.plugin.zsh  # thin wrapper (rewritten)
spec/                              # updated tests
```

## Migration Path

1. Build Rust binary with all subcommands
2. Rewrite zsh plugin as thin wrapper
3. Update tests for new architecture
4. Update CI for Rust builds
5. Add Homebrew formula
6. Update README
