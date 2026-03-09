# shellcheck shell=bash

# Disable compdef during tests (not available outside zsh completion system)
compdef() { :; }

# No-op editor opens during tests
export WT_OPENER=true

PLUGIN_PATH="$SHELLSPEC_PROJECT_ROOT/git-worktree-switcher.plugin.zsh"

# Resolve symlinks (macOS /var -> /private/var)
resolve_path() {
  cd "$1" && pwd -P
}

create_test_repo() {
  local tmpdir
  tmpdir=$(mktemp -d)
  tmpdir=$(resolve_path "$tmpdir")
  git -C "$tmpdir" init --quiet
  git -C "$tmpdir" config user.email "test@test.com"
  git -C "$tmpdir" config user.name "Test"
  git -C "$tmpdir" commit --allow-empty -m "initial" --quiet
  echo "$tmpdir"
}

add_test_worktree() {
  local main_wt="$1" name="$2"
  local target="$(dirname "$main_wt")/$name"
  git -C "$main_wt" worktree add -b "$name" "$target" --quiet 2>/dev/null
  echo "$target"
}

cleanup_test_repo() {
  local main_wt="$1"
  # Remove all worktrees first
  git -C "$main_wt" worktree list --porcelain | awk '/^worktree / {print substr($0, 10)}' | while read -r wt; do
    [[ "$wt" == "$main_wt" ]] && continue
    git -C "$main_wt" worktree remove --force "$wt" 2>/dev/null
  done
  rm -rf "$main_wt"
}
