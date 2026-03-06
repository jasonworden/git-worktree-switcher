# git-worktree-switcher - quickly switch between git worktrees using fzf

_wt_entries() {
  git worktree list --porcelain 2>/dev/null | awk '
    /^worktree / {
      if (length(path) > 0) { emit() }
      path = substr($0, 10)
      if (length(main) == 0) main = path
      branch = ""
    }
    /^branch / { branch = substr($0, 8); sub("refs/heads/", "", branch) }
    /^HEAD /   { if (length(branch) == 0) branch = "(detached)" }
    END { if (length(path) > 0) emit() }
    function emit() {
      rel = path
      if (path == main) { rel = "." }
      else { sub(main "/", "", rel) }
      printf "%s\t%s\t%s\n", branch, rel, path
    }
  '
}

wt() {
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  if [[ -n "$1" ]]; then
    # Resolve relative path or absolute path
    if [[ -d "$1" ]]; then
      cd "$1"
    else
      local main_wt=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}')
      cd "$main_wt/$1"
    fi
    return
  fi

  local folder=$'\uf07c'
  local branch_icon=$'\ue725'

  local raw=$(_wt_entries)
  [[ -z "$raw" ]] && return

  # Find max branch width for alignment
  local max_width=0
  while IFS=$'\t' read -r branch _ _; do
    (( ${#branch} > max_width )) && max_width=${#branch}
  done <<< "$raw"

  # Build aligned display with icons
  local selection=$(while IFS=$'\t' read -r branch rel abs; do
    printf "%s %-${max_width}s  %s %s\t%s\n" "$branch_icon" "$branch" "$folder" "$rel" "$abs"
  done <<< "$raw" | fzf --height=40% --delimiter='\t' --with-nth=1 --header="$branch_icon Branch$(printf '%*s' $((max_width - 4)) '')$folder Path")

  [[ -n "$selection" ]] || return
  cd "$(echo "$selection" | awk -F'\t' '{print $2}')"
}

_wt() {
  local -a wt_descs
  local branch_icon=$'\ue725'
  local folder=$'\uf07c'
  local branch rel abs
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(_wt_entries)
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt
