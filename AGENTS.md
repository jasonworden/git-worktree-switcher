# git-worktree-switcher — AI assistant guide

## Overview

Rust binary `wt-core` (worktree operations) plus a zsh plugin (`wt`, fzf, completions). Distributed via Homebrew (`jasonworden/tap/wt-core`).

## Architecture

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for full system design: data flow, TSV schema, verdict logic, config system, hooks, and known fzf limitations.

## Key paths

| Path | Purpose |
| --- | --- |
| `rust/` | Cargo crate, `wt-core` binary |
| `rust/src/unified.rs` | Core module: progressive loading, formatting, verdicts |
| `rust/src/config.rs` | Layered config: `.wt/config` TOML + git config + env |
| `git-worktree-switcher.plugin.zsh` | zsh wrapper: fzf lifecycle, cd, mode switching, hooks |
| `spec/` | ShellSpec tests |
| `dev.sh` | Dev helper: rebuild + reload (`source dev.sh`, then `wt-dev`) |
| `Formula/` | Homebrew formula |
| `docs/ARCHITECTURE.md` | System architecture and data flow |
| `.agents/skills/` | Project-specific agent skills |

## Pull requests

- Follow the root **`PULL_REQUEST_TEMPLATE.md`** for every PR.
- Prefer **draft** PRs until the branch is ready for review and merge (see skill `create-pull-request`).
- CI (**Validate PR description**): draft PRs and PRs labeled **`wip`** skip checks. Labels **`invalid`** and **`wontfix`** fail the check until removed. Other non-draft PRs must match the template (summary, type, release bump).

## Skills

Skills are directories under `.agents/skills/<name>/` with a `SKILL.md` file.

- **`create-pull-request`** — `.agents/skills/create-pull-request/` — use before opening a PR so the description matches repo standards.
