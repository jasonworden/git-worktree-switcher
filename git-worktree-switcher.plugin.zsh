# git-worktree-switcher - quickly switch between git worktrees using fzf

wt() {
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  local dir=$(git worktree list | fzf --height=40% | awk '{print $1}')
  [[ -n "$dir" ]] && cd "$dir"
}

_wt() {
  local -a worktrees
  worktrees=(${(f)"$(git worktree list 2>/dev/null | awk '{print $1}')"})
  compadd -V worktrees -- "${worktrees[@]}"
}
compdef _wt wt
