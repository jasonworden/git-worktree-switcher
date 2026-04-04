# git-worktree-switcher - quickly switch between git worktrees using fzf
# Thin zsh wrapper around the wt-core Rust binary.
#
# The anonymous function wrapper + emulate -LR zsh ensures that sourcing this
# file is immune to the user's shell options (xtrace, err_exit, etc.).

() {
emulate -LR zsh

# Editor used by ctrl-o in the fzf picker (supports multi-word commands)
: ${WT_OPENER:=code}

# Directory containing this file (for reinstall hints when wt-core is outdated)
: ${_wt_plugin_dir:="${${(%):-%x}:A:h}"}

# Verify wt-core binary is available
if ! command -v wt-core &>/dev/null; then
  echo "git-worktree-switcher: wt-core binary not found. Install via: brew install jasonworden/tap/wt-core" >&2
  return
fi

# ---------------------------------------------------------------------------
# wt clean
# ---------------------------------------------------------------------------
_wt_clean() {
  { set +x } 2>/dev/null   # silence even the trace of set +x
  emulate -LR zsh

  local keep_branches=false
  if [[ "$1" == "--keep-branches" ]] || [[ "${WT_CLEAN_KEEP_BRANCHES:-0}" == "1" ]]; then
    keep_branches=true
  fi

  local gh_flag=""
  if wt-core gh-available 2>/dev/null; then
    gh_flag="--gh"
  else
    echo "tip: brew install gh for PR merge detection" >&2
  fi

  echo "Fetching latest remote state..."

  local raw
  raw=$(wt-core clean-check $gh_flag 2>/dev/null)

  if [[ -z "$raw" ]]; then
    echo "No worktrees to clean (only main worktree exists)."
    return
  fi

  # --- Build fzf display lines (all in-process, no subshell) ---
  local c_green=$'\033[32m' c_yellow=$'\033[33m' c_red=$'\033[31m'
  local c_dim=$'\033[2m' c_bold=$'\033[1m' c_reset=$'\033[0m'
  local safe_char=$'\u2713' warn_char=$'\u26a0'

  local -a fzf_lines
  local verdict branch wt_path ev_pr ev_ahead ev_tree ev_remote
  local max_bw=0 max_pr=9 max_ah=5 max_tr=8 max_rm=6

  while IFS=$'\t' read -r verdict branch wt_path ev_pr ev_ahead ev_tree ev_remote; do
    (( ${#branch} > max_bw )) && max_bw=${#branch}
    (( ${#ev_pr} > max_pr )) && max_pr=${#ev_pr}
    (( ${#ev_ahead} > max_ah )) && max_ah=${#ev_ahead}
    (( ${#ev_tree} > max_tr )) && max_tr=${#ev_tree}
    (( ${#ev_remote} > max_rm )) && max_rm=${#ev_remote}
  done <<< "$raw"

  local icon disp pad cell
  while IFS=$'\t' read -r verdict branch wt_path ev_pr ev_ahead ev_tree ev_remote; do
    if [[ "$verdict" == "safe" ]]; then
      icon="${c_green}${safe_char}${c_reset}"
    else
      icon="${c_yellow}${warn_char}${c_reset}"
    fi

    disp="${icon} $(printf "${c_bold}%-${max_bw}s${c_reset}" "$branch")"

    # PR merged (optional)
    cell=""; [[ -n "$ev_pr" ]] && cell="${c_green}${ev_pr}${c_reset}"
    pad=$(( max_pr - ${#ev_pr} )); (( pad < 0 )) && pad=0
    disp+="  ${cell}$(printf '%*s' $pad '')"

    # commits ahead (optional)
    cell=""; [[ -n "$ev_ahead" ]] && cell="${c_yellow}${ev_ahead}${c_reset}"
    pad=$(( max_ah - ${#ev_ahead} )); (( pad < 0 )) && pad=0
    disp+="  ${cell}$(printf '%*s' $pad '')"

    # worktree clean / dirty
    if [[ "$ev_tree" == clean ]]; then cell="${c_dim}${ev_tree}${c_reset}"
    else cell="${c_red}${ev_tree}${c_reset}"; fi
    pad=$(( max_tr - ${#ev_tree} )); (( pad < 0 )) && pad=0
    disp+="  ${cell}$(printf '%*s' $pad '')"

    # remote gone (optional, last)
    cell=""; [[ -n "$ev_remote" ]] && cell="${c_green}${ev_remote}${c_reset}"
    pad=$(( max_rm - ${#ev_remote} )); (( pad < 0 )) && pad=0
    disp+="  ${cell}$(printf '%*s' $pad '')"

    fzf_lines+=("${disp}"$'\t'"${branch}"$'\t'"${wt_path}")
  done <<< "$raw"

  # --- fzf (output to tmpfile, not $()) ---
  local hdr
  hdr=$(printf "  %-${max_bw}s  %-${max_pr}s  %-${max_ah}s  %-${max_tr}s  %-${max_rm}s  │ tab:select · enter:delete · esc:cancel" "branch" "PR merged" "ahead" "tree" "remote")

  local fzf_out
  fzf_out=$(mktemp "${TMPDIR:-/tmp}/wt-clean.XXXXXX") || return
  printf '%s\n' "${fzf_lines[@]}" | fzf --multi --ansi --height=40% \
    --delimiter='\t' --with-nth=1 --header="$hdr" >"$fzf_out"

  [[ -s "$fzf_out" ]] || { rm -f "$fzf_out"; return }

  local selected
  selected=$(<"$fzf_out")
  rm -f "$fzf_out"
  [[ -n "$selected" ]] || return

  local -a paths branches
  local abs_path branch_name line
  while IFS= read -r line; do
    branch_name="${line#*$'\t'}"
    branch_name="${branch_name%%$'\t'*}"
    abs_path="${line##*$'\t'}"
    paths+=("$abs_path")
    branches+=("$branch_name")
  done <<< "$selected"

  local branch_msg=""
  if ! $keep_branches; then
    branch_msg=" (and local branches)"
  fi
  echo "Will delete ${#paths[@]} worktree(s)${branch_msg}:"
  for b in "${branches[@]}"; do echo "  - $b"; done
  echo
  printf "Proceed? [y/N] "
  read -q || { echo; return 1; }
  echo

  local main_wt
  main_wt=$(wt-core main-worktree)
  local wt_path branch
  for i in {1..${#paths[@]}}; do
    wt_path="${paths[$i]}"
    branch="${branches[$i]}"

    [[ "$PWD" == "$wt_path"* ]] && cd "$main_wt"

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

# ---------------------------------------------------------------------------
# wt add / wt delete
# ---------------------------------------------------------------------------
_wt_add() {
  { set +x } 2>/dev/null
  emulate -LR zsh

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
  { set +x } 2>/dev/null
  emulate -LR zsh

  local wt_path="$1"
  local name="$(basename "$wt_path")"

  printf "Remove worktree '%s'? [y/N] " "$name"
  read -q || { echo; return 1; }
  echo

  [[ "$PWD" == "$wt_path"* ]] && cd "$(wt-core main-worktree)"

  wt-core delete "$wt_path"
}

# ---------------------------------------------------------------------------
# wt (main entrypoint)
# ---------------------------------------------------------------------------
wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh

  if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "-V" ]]; then
    if ! wt-core --version 2>/dev/null; then
      echo "git-worktree-switcher: wt-core on PATH is too old (no --version). Reinstall from your clone:" >&2
      if [[ -d "${_wt_plugin_dir}/rust" ]]; then
        echo "  cd ${_wt_plugin_dir}/rust && cargo install --path . --force" >&2
      else
        echo "  cd rust && cargo install --path . --force" >&2
      fi
      return 1
    fi
    return
  fi

  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    cat <<'EOF'
Usage: wt [command] [args]

Commands:
  wt                Open fzf worktree picker
  wt add <branch>   Create new worktree (and branch if needed)
  wt clean          Review and batch-delete stale worktrees

fzf keybindings:
  enter    Switch to selected worktree
  ctrl-a   Create new worktree
  ctrl-o   Open in editor ($WT_OPENER, default: code)
  ctrl-x   Delete worktree (with confirmation)
  ctrl-g   Open cleanup helper (wt clean)
EOF
    return
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  # --- Subcommand dispatch ---

  if [[ "$1" == "clean" ]]; then
    _wt_clean "${@:2}"
    return
  fi

  if [[ "$1" == "add" ]]; then
    _wt_add "${@:2}"
    return
  fi

  if [[ -n "$1" ]]; then
    echo "wt: unknown command '$1'. Run wt for the picker, or wt --help." >&2
    return 1
  fi

  # --- Interactive fzf picker ---

  local folder=$'\uf07c'       # nerd font folder icon
  local branch_icon=$'\ue725'  # nerd font branch icon

  local raw ec=""
  raw=$(wt-core picker 2>&1) || ec=$?
  if [[ -n "$ec" || "$raw" == *"unrecognized subcommand"* ]]; then
    echo "git-worktree-switcher: wt-core on PATH is too old (missing \"picker\"). Reinstall from your clone:" >&2
    if [[ -d "${_wt_plugin_dir}/rust" ]]; then
      echo "  cd ${_wt_plugin_dir}/rust && cargo install --path . --force" >&2
    else
      echo "  cd rust && cargo install --path . --force" >&2
    fi
    [[ "$raw" != *"unrecognized subcommand"* && -n "$raw" ]] && echo "$raw" >&2
    return 1
  fi
  [[ -z "$raw" ]] && return

  local safe_icon=$'\u2713'
  local warn_icon=$'\u26a0'
  local main_abs=""
  local -a fzf_lines

  while IFS=$'\t' read -r branch rel abs stale; do
    [[ "$rel" == "." ]] && main_abs="$abs"
    local path_display="$rel"
    [[ "$rel" == "." ]] && path_display="${main_abs:t}"
    local status_icon=""
    [[ "$stale" == "safe" ]] && status_icon=" $safe_icon"
    [[ "$stale" == "warn" ]] && status_icon=" $warn_icon"
    fzf_lines+=("$(printf "%s %s  %s %s%s\t%s" \
      "$folder" "$path_display" "$branch_icon" "$branch" "$status_icon" "$abs")")
  done <<< "$raw"

  local fzf_out
  fzf_out=$(mktemp "${TMPDIR:-/tmp}/wt-fzf.XXXXXX") || return
  printf '%s\n' "${fzf_lines[@]}" | fzf --height=40% --delimiter='\t' --with-nth=1 \
    --header="enter:switch │ ctrl-a:add │ ctrl-o:open │ ctrl-x:delete │ ctrl-g:clean" \
    --expect=ctrl-o,ctrl-x,ctrl-a,ctrl-g >"$fzf_out"

  [[ -s "$fzf_out" ]] || { rm -f "$fzf_out"; return }

  local key=$(head -1 "$fzf_out")
  local selection=$(tail -1 "$fzf_out")
  rm -f "$fzf_out"
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

# ---------------------------------------------------------------------------
# Tab completion
# ---------------------------------------------------------------------------
_wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh

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

} # end anonymous function
