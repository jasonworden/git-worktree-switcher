#!/usr/bin/env zsh
# Dev helper: rebuild wt-core and reload the plugin.
# Source this file to get the wt-dev command:
#   source dev.sh
#
# Usage:
#   wt-dev                   — auto-detect from PWD (if in this repo) or plugin source
#   wt-dev /path/to/worktree — build from a specific worktree/checkout

wt-dev() {
  local root
  if [[ -n "$1" ]]; then
    root="$1"
  else
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n "$git_root" && -f "$git_root/rust/src/main.rs" ]]; then
      root="$git_root"
    else
      root="${_WT_PLUGIN_DIR:-$(cd "${0:A:h}" 2>/dev/null && pwd)}"
    fi
  fi
  if [[ ! -f "$root/rust/src/main.rs" ]]; then
    echo "Not a wt repo: $root" >&2
    return 1
  fi
  local branch
  branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  echo "wt-dev: $root (branch: $branch)"
  (cd "$root/rust" && cargo build --quiet) || return 1
  export PATH="$root/rust/target/debug:$PATH"
  source "$root/git-worktree-switcher.plugin.zsh"
  echo "wt-dev: rebuilt + reloaded"
}
