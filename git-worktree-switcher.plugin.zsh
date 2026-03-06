# git-worktree-switcher - quickly switch between git worktrees using fzf

wt() {
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  if [[ -n "$1" ]]; then
    cd "$1"
  else
    local dir=$(git worktree list | fzf --height=40% | awk '{print $1}')
    [[ -n "$dir" ]] && cd "$dir"
  fi
}

_wt() {
  local -a wt_list
  wt_list=(${(f)"$(git worktree list 2>/dev/null | awk '{print $1}')"})
  compadd -f -V worktrees -- "${wt_list[@]}"
}
compdef _wt wt
