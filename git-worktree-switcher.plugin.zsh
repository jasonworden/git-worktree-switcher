# git-worktree-switcher - unified worktree manager using fzf
# Thin zsh wrapper around the wt-core Rust binary.
#
# Three modes: browse (default), uproot (cleanup), plant (create).
# Progressive loading: local data instant, remote enriched via fzf --listen.

() {
emulate -LR zsh

# Editor used by ctrl-o in the fzf picker (supports multi-word commands)
: ${WT_OPENER:=code}

# Directory containing this file (for reinstall hints)
: ${_wt_plugin_dir:="${${(%):-%x}:A:h}"}

# Verify wt-core binary is available
if ! command -v wt-core &>/dev/null; then
  echo "git-worktree-switcher: wt-core binary not found. Install via: brew install jasonworden/tap/wt-core" >&2
  return
fi

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
_wt_run_hook() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local hook_name="$1" wt_path="$2" wt_branch="$3" is_new="$4"
  local main_wt
  main_wt=$(wt-core main-worktree 2>/dev/null)

  # git config override takes priority
  local hook_cmd
  hook_cmd=$(git config --get "wt.hook.${hook_name}" 2>/dev/null)

  if [[ -z "$hook_cmd" ]]; then
    local hook_file
    if [[ -n "$main_wt" ]]; then
      hook_file="${main_wt}/.wt/hooks/${hook_name}.sh"
    fi
    if [[ -x "$hook_file" ]]; then
      hook_cmd="$hook_file"
    elif [[ -f "$hook_file" ]]; then
      hook_cmd="sh $hook_file"
    fi
  fi

  [[ -z "$hook_cmd" ]] && return 0

  export WT_BRANCH="$wt_branch"
  export WT_PATH="$wt_path"
  export WT_MAIN_PATH="${main_wt:-}"
  export WT_IS_NEW="$is_new"

  (cd "$wt_path" && eval "$hook_cmd") </dev/null || {
    echo "warning: ${hook_name} hook exited with error" >&2
  }
}

# ---------------------------------------------------------------------------
# wt (main entrypoint)
# ---------------------------------------------------------------------------
wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh

  if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "-V" ]]; then
    wt-core --version 2>/dev/null || {
      echo "git-worktree-switcher: wt-core too old. Reinstall." >&2; return 1
    }
    return
  fi

  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    cat <<'EOF'
Usage: wt [command] [args]

Commands:
  wt                Open worktree picker (browse mode)
  wt uproot         Open in uproot mode (bulk cleanup)
  wt clean          Alias for wt uproot
  wt plant          Open in plant mode (create worktree)
  wt add <branch>   Create new worktree (legacy, use wt plant)

Modes (switch within picker):
  alt-1                       Switch to browse mode
  alt-2                       Switch to uproot mode
  alt-3                       Switch to plant mode
  ctrl-]                      Cycle: browse -> uproot -> plant
  esc                         Back to browse mode

Browse keybindings:
  enter    Switch to selected worktree
  tab      Toggle multi-select
  ctrl-o   Open in editor ($WT_OPENER)
  ctrl-x   Delete worktree (with confirmation)
EOF
    return
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository" >&2
    return 1
  fi

  # --- Subcommand dispatch ---
  local initial_mode="browse"
  case "$1" in
    uproot|clean) initial_mode="uproot"; shift ;;
    plant)        initial_mode="plant"; shift ;;
    add)          _wt_add "${@:2}"; return ;;
    "")           ;;
    *)            echo "wt: unknown command '$1'. Run wt --help." >&2; return 1 ;;
  esac

  _wt_picker "$initial_mode" "$@"
}

# ---------------------------------------------------------------------------
# Unified fzf picker
# ---------------------------------------------------------------------------
_wt_picker() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local initial_mode="${1:-browse}"

  # Verify data exists
  local check
  check=$(wt-core unified --local 2>/dev/null)
  [[ -z "$check" ]] && return

  # Temp files
  local tmpdir="${TMPDIR:-/tmp}"
  local fzf_out=$(mktemp "${tmpdir}/wt-fzf.XXXXXX")
  local mode_file=$(mktemp "${tmpdir}/wt-mode.XXXXXX")
  echo "$initial_mode" > "$mode_file"

  # Headers per mode
  local browse_hdr=$'\033[33m\u21bb Loading...\033[0m  /uproot \u00b7 /plant \u00b7 enter cd \u00b7 ctrl-o open'
  local browse_hdr_done=$'\033[32m\u2713 Ready\033[0m  /uproot \u00b7 /plant \u00b7 enter cd \u00b7 ctrl-o open'
  local uproot_hdr=$'\033[31m\u26a0 UPROOT MODE\033[0m  tab select \u00b7 enter confirm \u00b7 esc browse'
  local plant_hdr="Select branch or [new branch] \u00b7 esc cancel"

  # Preview command (uses abs path from last tab-delimited field)
  local preview_cmd='wt-core unified --preview {-1} 2>/dev/null'

  if [[ "$initial_mode" == "plant" ]]; then
    # Plant mode: simple branch picker
    wt-core unified --branches 2>/dev/null | \
      fzf --ansi --height=40% --header="$plant_hdr" --prompt="plant> " > "$fzf_out"

    [[ -s "$fzf_out" ]] || { rm -f "$fzf_out" "$mode_file"; return; }
    local selection=$(<"$fzf_out")
    rm -f "$fzf_out" "$mode_file"
    _wt_handle_plant "$selection"
    return
  fi

  # Browse or Uproot mode — use fzf with reload for progressive loading
  local format_flag="browse"
  local prompt_str="> "
  local header="$browse_hdr"
  local -a extra_args=()

  if [[ "$initial_mode" == "uproot" ]]; then
    format_flag="uproot"
    prompt_str="uproot> "
    header="$uproot_hdr"
    extra_args+=(--multi)
  fi

  # The key trick: fzf starts with --local data, then a bind triggers --remote reload.
  # We use 'start' binding (fzf 0.44+) or 'load' binding to trigger the background reload.
  # For broader compat, we use become/execute-silent + reload pattern.

  local reload_cmd="wt-core unified --remote --format=${format_flag} 2>/dev/null"
  local local_cmd="wt-core unified --local --format=${format_flag} 2>/dev/null"

  wt-core unified --local --format="$format_flag" 2>/dev/null | \
    fzf --ansi --height=60% \
      --delimiter=$'\t' --with-nth=1 \
      --header="$header" \
      --prompt="$prompt_str" \
      --preview="$preview_cmd" \
      --preview-window=right:40%:wrap \
      --expect=ctrl-o,ctrl-x \
      --bind="tab:toggle+down" \
      --bind="load:reload-sync($reload_cmd)+change-header($browse_hdr_done)" \
      --bind="alt-1:reload($local_cmd)+change-header($browse_hdr_done)+change-prompt(> )" \
      --bind="alt-2:reload(wt-core unified --remote --format=uproot 2>/dev/null)+change-header($uproot_hdr)+change-prompt(uproot> )" \
      --bind="alt-3:become(echo __PLANT__)" \
      --bind="ctrl-]:become(echo __CYCLE__)" \
      --bind="esc:reload($local_cmd)+change-header($browse_hdr_done)+change-prompt(> )" \
      "${extra_args[@]}" > "$fzf_out"

  [[ -s "$fzf_out" ]] || { rm -f "$fzf_out" "$mode_file"; return; }

  # Check for mode-switch signals from become() bindings
  local first_line=$(<"$fzf_out")
  if [[ "$first_line" == "__PLANT__" ]]; then
    rm -f "$fzf_out" "$mode_file"
    _wt_picker "plant"
    return
  fi
  if [[ "$first_line" == "__CYCLE__" ]]; then
    rm -f "$fzf_out" "$mode_file"
    # Cycle: browse -> uproot -> plant -> browse
    case "$initial_mode" in
      browse) _wt_picker "uproot" ;;
      uproot) _wt_picker "plant" ;;
      *)      _wt_picker "browse" ;;
    esac
    return
  fi

  local key=$(head -1 "$fzf_out")

  if [[ "$initial_mode" == "uproot" || "$prompt_str" == "uproot> " ]]; then
    local -a selected_lines
    selected_lines=("${(@f)$(tail -n +2 "$fzf_out")}")
    rm -f "$fzf_out" "$mode_file"
    _wt_handle_uproot "${selected_lines[@]}"
    return
  fi

  # Browse mode result
  local selection=$(tail -1 "$fzf_out")
  rm -f "$fzf_out" "$mode_file"
  [[ -n "$selection" ]] || return

  local abs_path=$(echo "$selection" | awk -F'\t' '{print $NF}')
  [[ -n "$abs_path" ]] || return

  case "$key" in
    ctrl-o) ${(z)WT_OPENER} "$abs_path" ;;
    ctrl-x) _wt_delete "$abs_path" ;;
    *)
      cd "$abs_path"
      local branch
      branch=$(git -C "$abs_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      _wt_run_hook "post-enter" "$abs_path" "${branch:-unknown}" "false"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Plant handler
# ---------------------------------------------------------------------------
_wt_handle_plant() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local selection="$1"

  if [[ "$selection" == "[new branch]" ]]; then
    printf "Branch name: "
    local branch_name
    read -r branch_name
    [[ -n "$branch_name" ]] || return

    local enforce_prefix
    enforce_prefix=$(git config --get wt.opinionated.branchPrefix 2>/dev/null)
    if [[ "$enforce_prefix" == "true" ]]; then
      if [[ "$branch_name" != feat/* && "$branch_name" != fix/* && "$branch_name" != chore/* ]]; then
        echo "Opinionated mode: branch must start with feat/, fix/, or chore/"
        printf "Branch name: "
        read -r branch_name
        [[ -n "$branch_name" ]] || return
      fi
    fi

    selection="$branch_name"
  fi

  local target
  target=$(wt-core add "$selection" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "Failed: $target" >&2
    return 1
  fi

  echo "Created worktree: $selection -> $target"
  _wt_run_hook "post-plant" "$target" "$selection" "true"

  local auto_cd
  auto_cd=$(git config --get wt.opinionated.autoCd 2>/dev/null)
  if [[ "$auto_cd" == "true" ]]; then
    cd "$target"
  else
    printf "cd into %s? [Y/n] " "$target"
    local yn
    read -r yn
    [[ "$yn" != [nN]* ]] && cd "$target"
  fi
}

# ---------------------------------------------------------------------------
# Uproot handler
# ---------------------------------------------------------------------------
_wt_handle_uproot() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local -a lines=("$@")
  [[ ${#lines[@]} -gt 0 ]] || return

  local keep_branches=false
  [[ "${WT_CLEAN_KEEP_BRANCHES:-0}" == "1" ]] && keep_branches=true

  local delete_branch
  delete_branch=$(git config --get wt.opinionated.deleteBranch 2>/dev/null)
  [[ "$delete_branch" == "true" ]] && keep_branches=false

  # Main guard: resolve default branch name
  local main_guard
  main_guard=$(git config --get wt.opinionated.mainGuard 2>/dev/null)
  local default_branch
  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "main")
  default_branch="${default_branch#origin/}"

  local -a paths branches
  local line abs_path branch_name
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    abs_path=$(echo "$line" | awk -F'\t' '{print $NF}')
    # Extract branch: strip ANSI, trim leading spaces, take first word
    branch_name=$(echo "$line" | sed $'s/\033\\[[0-9;]*m//g' | sed 's/^[[:space:]]*//' | awk '{print $1}')
    [[ -n "$abs_path" && -n "$branch_name" ]] || continue
    # Skip main worktree (pinned verdict or main guard)
    [[ "$branch_name" == "pinned" ]] && continue
    if [[ "$main_guard" == "true" && "$branch_name" == "$default_branch" ]]; then
      echo "Skipping $branch_name (main guard enabled)" >&2
      continue
    fi
    paths+=("$abs_path")
    branches+=("$branch_name")
  done

  [[ ${#paths[@]} -gt 0 ]] || return

  local branch_msg=""
  $keep_branches || branch_msg=" (and local branches)"
  echo "Will delete ${#paths[@]} worktree(s)${branch_msg}:"
  for b in "${branches[@]}"; do echo "  - $b"; done
  echo
  printf "Proceed? [y/N] "
  read -q || { echo; return 1; }
  echo

  local main_wt
  main_wt=$(wt-core main-worktree)

  local i wt_path branch
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
      echo "Failed to remove: $branch" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Legacy helpers
# ---------------------------------------------------------------------------
_wt_add() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  [[ -z "$1" ]] && { echo "Usage: wt add <branch-name>" >&2; return 1; }

  local target
  target=$(wt-core add "$1")
  [[ $? -ne 0 ]] && return 1

  _wt_run_hook "post-plant" "$target" "$1" "true"
  cd "$target"

  printf "Open in %s? [Y/n] " "$WT_OPENER"
  local open_yn
  read -r open_yn
  [[ "$open_yn" != [nN]* ]] && ${(z)WT_OPENER} "$target"
  return 0
}

_wt_delete() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local wt_path="$1"
  printf "Remove worktree '%s'? [y/N] " "$(basename "$wt_path")"
  read -q || { echo; return 1; }
  echo
  [[ "$PWD" == "$wt_path"* ]] && cd "$(wt-core main-worktree)"
  wt-core delete "$wt_path"
}

# ---------------------------------------------------------------------------
# Tab completion
# ---------------------------------------------------------------------------
_wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local branch_icon=$'\ue725'

  if [[ "$words[2]" == "add" || "$words[2]" == "plant" ]]; then
    local -a branches
    branches=(${(f)"$(wt-core completions 2>/dev/null)"})
    _describe 'branch' branches
    return
  fi

  local -a wt_descs subcmds
  subcmds=(
    "plant:Create a new worktree"
    "uproot:Review and bulk-delete stale worktrees"
    "clean:Alias for uproot"
    "add:Create a new worktree (legacy)"
  )
  local branch rel abs
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(wt-core entries 2>/dev/null)
  _describe 'subcommand' subcmds -V subcommands
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt

} # end anonymous function
