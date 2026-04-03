# git-worktree-switcher - quickly switch between git worktrees using fzf
# Thin zsh wrapper around the wt-core Rust binary.

# Editor used by ctrl-o in the fzf picker (supports multi-word commands)
: ${WT_OPENER:=code}

# Verify wt-core binary is available
if ! command -v wt-core &>/dev/null; then
  echo "git-worktree-switcher: wt-core binary not found. Install via: brew install jasonworden/tap/wt-core" >&2
  return 1 2>/dev/null || exit 1
fi

_wt_clean() {
  local keep_branches=false
  if [[ "$1" == "--keep-branches" ]] || [[ "${WT_CLEAN_KEEP_BRANCHES:-0}" == "1" ]]; then
    keep_branches=true
  fi

  # Check gh availability
  local gh_flag=""
  if wt-core gh-available 2>/dev/null; then
    gh_flag="--gh"
  else
    echo "tip: brew install gh for PR merge detection" >&2
  fi

  echo "Fetching latest remote state..."

  # Get all verdicts from wt-core (it handles fetch + PR queries internally)
  local raw
  raw=$(wt-core clean-check $gh_flag 2>/dev/null)

  if [[ -z "$raw" ]]; then
    echo "No worktrees to clean (only main worktree exists)."
    return
  fi

  # Format for fzf: icon + branch + evidence, with abs_path after tab
  local c_green=$'\033[32m' c_yellow=$'\033[33m' c_red=$'\033[31m'
  local c_dim=$'\033[2m' c_bold=$'\033[1m' c_reset=$'\033[0m'
  local safe_char=$'\u2713' warn_char=$'\u26a0' dot=$'\u00b7'

  local fzf_lines=()
  local verdict branch wt_path evidence icon colored_evidence p colored_p
  local -a pieces

  # Compute max branch width for column alignment
  local max_branch_width=0
  while IFS=$'\t' read -r verdict branch _ _; do
    (( ${#branch} > max_branch_width )) && max_branch_width=${#branch}
  done <<< "$raw"

  while IFS=$'\t' read -r verdict branch wt_path evidence; do
    if [[ "$verdict" == "safe" ]]; then
      icon="${c_green}${safe_char}${c_reset}"
    else
      icon="${c_yellow}${warn_char}${c_reset}"
    fi

    # Colorize individual evidence pieces
    colored_evidence=""
    pieces=("${(@s: · :)evidence}")
    for p in "${pieces[@]}"; do
      case "$p" in
        PR\ *merged)       colored_p="${c_green}${p}${c_reset}" ;;
        remote\ gone)      colored_p="${c_green}${p}${c_reset}" ;;
        clean)             colored_p="${c_dim}${p}${c_reset}" ;;
        *commit*ahead*)    colored_p="${c_yellow}${p}${c_reset}" ;;
        uncommitted*)      colored_p="${c_red}${p}${c_reset}" ;;
        *)                 colored_p="$p" ;;
      esac
      if [[ -n "$colored_evidence" ]]; then
        colored_evidence="${colored_evidence} ${c_dim}${dot}${c_reset} ${colored_p}"
      else
        colored_evidence="$colored_p"
      fi
    done

    fzf_lines+=("$(printf "%s ${c_bold}%-${max_branch_width}s${c_reset}  %s\t%s" "$icon" "$branch" "$colored_evidence" "$wt_path")")
  done <<< "$raw"

  # fzf multi-select
  local selected
  selected=$(printf '%s\n' "${fzf_lines[@]}" | fzf --multi --ansi --height=40% \
    --delimiter='\t' --with-nth=1 \
    --header="tab:select | enter:delete selected | esc:cancel")

  [[ -n "$selected" ]] || return

  # Extract paths and branch names from selection
  local -a paths branches
  local abs_path branch_name
  while IFS= read -r line; do
    abs_path=$(echo "$line" | awk -F'\t' '{print $2}')
    branch_name=$(echo "$line" | awk '{print $2}')
    paths+=("$abs_path")
    branches+=("$branch_name")
  done <<< "$selected"

  # Confirmation
  local branch_msg=""
  if ! $keep_branches; then
    branch_msg=" (and local branches)"
  fi
  echo "Will delete ${#paths[@]} worktree(s)${branch_msg}:"
  for b in "${branches[@]}"; do
    echo "  - $b"
  done
  echo
  printf "Proceed? [y/N] "
  read -q || { echo; return 1; }
  echo

  # Batch delete
  local main_wt
  main_wt=$(wt-core main-worktree)
  local wt_path branch
  for i in {1..${#paths[@]}}; do
    wt_path="${paths[$i]}"
    branch="${branches[$i]}"

    if [[ "$PWD" == "$wt_path"* ]]; then
      cd "$main_wt"
    fi

    if wt-core delete "$wt_path" 2>/dev/null; then
      echo "Removed worktree: $branch"
      if ! $keep_branches; then
        git branch -D "$branch" 2>/dev/null && echo "Deleted branch: $branch"
      fi
    else
      echo "Failed to remove worktree: $branch (may have changes -- use git worktree remove --force)" >&2
    fi
  done
}

_wt_add() {
  if [[ -z "$1" ]]; then
    echo "Usage: wt add <branch-name>" >&2
    return 1
  fi

  local target
  target=$(wt-core add "$1")
  if [[ $? -ne 0 ]]; then
    return 1
  fi

  cd "$target"

  printf "Open in %s? [Y/n] " "$WT_OPENER"
  local open_yn
  read -r open_yn
  if [[ "$open_yn" != [nN]* ]]; then
    ${(z)WT_OPENER} "$target"
  fi
}

_wt_delete() {
  local wt_path="$1"
  local name="$(basename "$wt_path")"

  printf "Remove worktree '%s'? [y/N] " "$name"
  read -q || { echo; return 1; }
  echo

  # Can't remove a worktree while we're inside it
  if [[ "$PWD" == "$wt_path"* ]]; then
    cd "$(wt-core main-worktree)"
  fi

  wt-core delete "$wt_path"
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
  wt clean            Review and batch-delete stale worktrees

fzf keybindings:
  enter    Switch to selected worktree
  ctrl-a   Create new worktree
  ctrl-o   Open in editor ($WT_OPENER, default: code)
  ctrl-x   Delete worktree (with confirmation)
  ctrl-g   Open cleanup helper (wt clean)
EOF
    return
  fi

  if [[ "$1" == "clean" ]]; then
    _wt_clean "${@:2}"
    return
  fi

  if [[ "$1" == "add" ]]; then
    _wt_add "${@:2}"
    return
  fi

  # Direct path: `wt some/path` cds straight there
  if [[ -n "$1" ]]; then
    local main_wt
    main_wt=$(wt-core main-worktree)
    local target
    if [[ "$1" == "." ]]; then
      target="$main_wt"
    elif [[ -d "$1" ]]; then
      target="$1"
    else
      target="$main_wt/$1"
    fi
    cd "$target" || return 1

    printf "Open in %s? [Y/n] " "$WT_OPENER"
    local open_yn
    read -r open_yn
    if [[ "$open_yn" != [nN]* ]]; then
      ${(z)WT_OPENER} "$target"
    fi
    return
  fi

  # --- Interactive fzf picker ---

  local folder=$'\uf07c'       # nerd font folder icon
  local branch_icon=$'\ue725'  # nerd font branch icon

  local raw
  raw=$(wt-core entries)
  [[ -z "$raw" ]] && return

  # Find max branch width for column alignment
  local max_width=0
  while IFS=$'\t' read -r branch _ _; do
    (( ${#branch} > max_width )) && max_width=${#branch}
  done <<< "$raw"

  # Format entries for fzf with staleness indicators
  local safe_icon=$'\u2713'
  local warn_icon=$'\u26a0'
  local main_abs default_branch
  main_abs=$(wt-core main-worktree)
  default_branch=$(wt-core default-branch)

  local status_icon status
  local result=$(while IFS=$'\t' read -r branch rel abs <&3; do
    status_icon=""
    if [[ "$branch" != "(detached)" && "$abs" != "$main_abs" ]]; then
      status=$(wt-core quick-status "$branch" "$abs" "$default_branch" 2>/dev/null)
      [[ "$status" == "safe" ]] && status_icon=" $safe_icon"
      [[ "$status" == "warn" ]] && status_icon=" $warn_icon"
    fi
    printf "%s %-${max_width}s%s  %s %s\t%s\n" \
      "$branch_icon" "$branch" "$status_icon" "$folder" "$rel" "$abs"
  done 3<<< "$raw" | fzf --height=40% --delimiter='\t' --with-nth=1 \
    --header="enter:switch │ ctrl-a:add │ ctrl-o:open │ ctrl-x:delete │ ctrl-g:clean" \
    --expect=ctrl-o,ctrl-x,ctrl-a,ctrl-g)

  [[ -n "$result" ]] || return

  local key=$(head -1 <<< "$result")
  local selection=$(tail -1 <<< "$result")
  [[ -n "$selection" ]] || return

  local abs_path=$(echo "$selection" | awk -F'\t' '{print $2}')

  case "$key" in
    ctrl-a)
      printf "Branch name: "
      local branch_name
      read -r branch_name
      [[ -n "$branch_name" ]] && _wt_add "$branch_name"
      ;;
    ctrl-o) ${(z)WT_OPENER} "$abs_path" ;;
    ctrl-x) _wt_delete "$abs_path" ;;
    ctrl-g) _wt_clean ;;
    *)      cd "$abs_path" ;;
  esac
}

# --- Tab completion ---
_wt() {
  local branch_icon=$'\ue725'
  local branch rel abs

  if [[ "$words[2]" == "add" ]]; then
    local -a branches
    branches=(${(f)"$(wt-core completions 2>/dev/null)"})
    _describe 'branch' branches
    return
  fi

  local -a wt_descs subcmds
  subcmds=("add:Create a new worktree" "clean:Review and delete stale worktrees")
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(wt-core entries 2>/dev/null)
  _describe 'subcommand' subcmds -V subcommands
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt
