# git-worktree-switcher - quickly switch between git worktrees using fzf

# Editor used by ctrl-o in the fzf picker (supports aliases)
: ${WT_OPENER:=code}

# Parse `git worktree list --porcelain` into tab-delimited rows:
#   branch_name \t relative_path \t absolute_path
# The main worktree's relative path is shown as "."
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

# Returns the absolute path of the main (first) worktree
_wt_main_worktree() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}'
}

# Create a new worktree as a sibling directory of the main worktree.
# If a local branch with the given name exists, it's checked out;
# otherwise a new branch is created.
_wt_add() {
  if [[ -z "$1" ]]; then
    echo "Usage: wt add <branch-name>" >&2
    return 1
  fi
  local name="$1"
  local main_wt=$(_wt_main_worktree)
  local target="$(dirname "$main_wt")/$name"

  # Use existing branch if it exists, otherwise create a new one with -b
  if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    git worktree add "$target" "$name"
  else
    git worktree add -b "$name" "$target"
  fi

  [[ $? -eq 0 ]] && cd "$target"
}

# Remove a worktree by absolute path, with a confirmation prompt.
# Safely handles the case where the user is cd'd into the worktree
# being deleted by moving them to the main worktree first.
_wt_delete() {
  local wt_path="$1"
  local name=$(basename "$wt_path")

  printf "Remove worktree '%s'? [y/N] " "$name"
  read -q || { echo; return 1; }
  echo

  # Can't remove a worktree while we're inside it
  if [[ "$PWD" == "$wt_path"* ]]; then
    cd "$(_wt_main_worktree)"
  fi

  git worktree remove "$wt_path"
}

wt() {
  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  # --- Subcommand dispatch ---

  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    cat <<'EOF'
Usage: wt [command] [args]

Commands:
  wt                Open fzf worktree picker
  wt <path>         Switch to worktree at path
  wt add <branch>   Create new worktree (and branch if needed)

fzf keybindings:
  enter    Switch to selected worktree
  ctrl-o   Open in editor ($WT_OPENER, default: code)
  ctrl-x   Delete worktree (with confirmation)
  ctrl-a   Create new worktree
EOF
    return
  fi

  if [[ "$1" == "add" ]]; then
    _wt_add "${@:2}"
    return
  fi

  # Direct path: `wt some/path` cds straight there
  if [[ -n "$1" ]]; then
    if [[ -d "$1" ]]; then
      cd "$1"
    else
      # Try as a path relative to the main worktree
      local main_wt=$(_wt_main_worktree)
      cd "$main_wt/$1"
    fi
    return
  fi

  # --- Interactive fzf picker ---

  local folder=$'\uf07c'       # nerd font folder icon
  local branch_icon=$'\ue725'  # nerd font branch icon

  local raw=$(_wt_entries)
  [[ -z "$raw" ]] && return

  # Find max branch width for column alignment
  local max_width=0
  while IFS=$'\t' read -r branch _ _; do
    (( ${#branch} > max_width )) && max_width=${#branch}
  done <<< "$raw"

  # Format entries as "icon branch  icon path\tabs_path" for fzf.
  # --with-nth=1 shows only the display portion (before \t).
  # --expect makes fzf output the pressed key on line 1, selection on line 2.
  local result=$(while IFS=$'\t' read -r branch rel abs; do
    printf "%s %-${max_width}s  %s %s\t%s\n" "$branch_icon" "$branch" "$folder" "$rel" "$abs"
  done <<< "$raw" | fzf --height=40% --delimiter='\t' --with-nth=1 \
    --header="enter:switch │ ctrl-a:add │ ctrl-o:open │ ctrl-x:delete" \
    --expect=ctrl-o,ctrl-x,ctrl-a)

  [[ -n "$result" ]] || return

  # --expect changes fzf output: line 1 = key pressed (empty for enter), line 2 = selection
  local key=$(head -1 <<< "$result")
  local selection=$(tail -1 <<< "$result")
  [[ -n "$selection" ]] || return

  local abs_path=$(echo "$selection" | awk -F'\t' '{print $2}')

  case "$key" in
    ctrl-a)
      printf "Branch name: "
      local branch_name
      read -r branch_name
      if [[ -n "$branch_name" ]]; then
        _wt_add "$branch_name"
        if [[ $? -eq 0 ]]; then
          local target="$(dirname "$(_wt_main_worktree)")/$branch_name"
          printf "Open in %s? [Y/n] " "$WT_OPENER"
          local open_yn
          read -r open_yn
          if [[ "$open_yn" != [nN]* ]]; then
            eval "$WT_OPENER \"$target\""
          fi
        fi
      fi
      ;;
    ctrl-o) eval "$WT_OPENER \"$abs_path\"" ;;
    ctrl-x) _wt_delete "$abs_path" ;;
    *)      cd "$abs_path" ;;
  esac
}

# --- Tab completion ---
# `wt <tab>` shows subcommands + worktree paths
# `wt add <tab>` shows local and remote branch names
_wt() {
  local branch_icon=$'\ue725'
  local branch rel abs

  if [[ "$words[2]" == "add" ]]; then
    local -a branches
    branches=(${(f)"$(git branch -a --format='%(refname:short)' 2>/dev/null)"})
    _describe 'branch' branches
    return
  fi

  local -a wt_descs subcmds
  subcmds=("add:Create a new worktree")
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(_wt_entries)
  _describe 'subcommand' subcmds -V subcommands
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt
