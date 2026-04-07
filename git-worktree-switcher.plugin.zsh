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
    # Fall back to .wt/hooks/<hook_name>.sh
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

  (cd "$wt_path" && eval "$hook_cmd") || {
    echo "warning: ${hook_name} hook exited with error" >&2
  }
}

# ---------------------------------------------------------------------------
# Format TSV into fzf display lines
# ---------------------------------------------------------------------------
_wt_format_browse() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local raw="$1"
  local c_green=$'\033[32m' c_yellow=$'\033[33m' c_red=$'\033[31m'
  local c_dim=$'\033[2m' c_bold=$'\033[1m' c_reset=$'\033[0m'
  local c_cyan=$'\033[36m'

  local branch rel abs tree ahead remote pr verdict is_main
  while IFS=$'\t' read -r branch rel abs tree ahead remote pr verdict is_main; do
    local indicator=" "
    [[ "$is_main" == "true" ]] && indicator="${c_green}\u25cf${c_reset}"

    local branch_col
    if [[ "$is_main" == "true" ]]; then
      branch_col="${c_green}${branch}${c_reset}"
    else
      branch_col="${c_cyan}${branch}${c_reset}"
    fi

    local tree_col
    if [[ "$tree" == "clean" ]]; then
      tree_col="${c_green}clean${c_reset}"
    else
      tree_col="${c_red}dirty${c_reset}"
    fi

    local ahead_col
    if [[ "$ahead" == $'\u2014' || "$ahead" == "—" ]]; then
      ahead_col="${c_dim}\u2014${c_reset}"
    else
      ahead_col="${c_yellow}${ahead}${c_reset}"
    fi

    local remote_col
    case "$remote" in
      *gone*)    remote_col="${c_red}gone${c_reset}" ;;
      *origin*)  remote_col="${c_green}origin \u2713${c_reset}" ;;
      "··")      remote_col="${c_dim}\u00b7\u00b7${c_reset}" ;;
      *)         remote_col="${c_dim}\u2014${c_reset}" ;;
    esac

    local pr_col
    case "$pr" in
      *merged*)  pr_col="${c_green}${pr}${c_reset}" ;;
      "··")      pr_col="${c_dim}\u00b7\u00b7${c_reset}" ;;
      *)         pr_col="${c_dim}${pr}${c_reset}" ;;
    esac

    printf "%s %-20s %-24s %-7s %-7s %-12s %s\t%s\n" \
      "$indicator" "$branch_col" "${c_dim}${rel}${c_reset}" \
      "$tree_col" "$ahead_col" "$remote_col" "$pr_col" "$abs"
  done <<< "$raw"
}

_wt_format_uproot() {
  { set +x } 2>/dev/null
  emulate -LR zsh
  local raw="$1"
  local c_green=$'\033[32m' c_yellow=$'\033[33m' c_red=$'\033[31m'
  local c_dim=$'\033[2m' c_bold=$'\033[1m' c_reset=$'\033[0m'
  local c_cyan=$'\033[36m'

  local branch rel abs tree ahead remote pr verdict is_main
  while IFS=$'\t' read -r branch rel abs tree ahead remote pr verdict is_main; do
    local indicator=" "
    local verdict_col

    if [[ "$is_main" == "true" ]]; then
      # Grayed out, not selectable
      printf "${c_dim}  %-20s %-24s %-7s %-7s %-12s %-14s pinned${c_reset}\t%s\n" \
        "$branch" "$rel" "$tree" "$ahead" "$remote" "$pr" "$abs"
      continue
    fi

    case "$verdict" in
      safe)    verdict_col="${c_green}safe \u2713${c_reset}" ;;
      keep)    verdict_col="${c_yellow}keep${c_reset}" ;;
      unsafe)  verdict_col="${c_red}unsafe${c_reset}" ;;
      pending) verdict_col="${c_dim}...${c_reset}" ;;
      *)       verdict_col="${c_dim}${verdict}${c_reset}" ;;
    esac

    printf "  %-20s %-24s %-7s %-7s %-12s %-14s %s\t%s\n" \
      "${c_cyan}${branch}${c_reset}" "${c_dim}${rel}${c_reset}" \
      "$(if [[ $tree == clean ]]; then echo "${c_green}clean${c_reset}"; else echo "${c_red}dirty${c_reset}"; fi)" \
      "$(if [[ "$ahead" == $'\u2014' || "$ahead" == "—" ]]; then echo "${c_dim}\u2014${c_reset}"; else echo "${c_yellow}${ahead}${c_reset}"; fi)" \
      "$(case $remote in *gone*) echo "${c_red}gone${c_reset}";; *origin*) echo "${c_green}origin \u2713${c_reset}";; "··") echo "${c_dim}\u00b7\u00b7${c_reset}";; *) echo "${c_dim}\u2014${c_reset}";; esac)" \
      "$(case $pr in *merged*) echo "${c_green}${pr}${c_reset}";; "··") echo "${c_dim}\u00b7\u00b7${c_reset}";; *) echo "${c_dim}${pr}${c_reset}";; esac)" \
      "$verdict_col" "$abs"
  done <<< "$raw"
}

# ---------------------------------------------------------------------------
# wt (main entrypoint)
# ---------------------------------------------------------------------------
wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh

  if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "-V" ]]; then
    wt-core --version 2>/dev/null || {
      echo "git-worktree-switcher: wt-core too old. Reinstall from your clone." >&2
      return 1
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
  /browse, /uproot, /plant    Slash commands
  alt-1, alt-2, alt-3         Direct jump
  ctrl-]                      Cycle modes
  esc                         Back to browse

Browse keybindings:
  enter    Switch to selected worktree (or open selected in editor)
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
    "")           ;; # default browse
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
  local keep_branches_flag="$2"

  # Get initial local data
  local raw_local
  raw_local=$(wt-core unified --local 2>/dev/null)
  [[ -z "$raw_local" ]] && return

  # Check fzf version for --listen support
  local fzf_version
  fzf_version=$(fzf --version 2>/dev/null | head -1 | sed 's/[^0-9.].*//; s/\..*//')
  local fzf_minor
  fzf_minor=$(fzf --version 2>/dev/null | head -1 | sed 's/[^0-9.].*//; s/^[0-9]*\.//; s/\..*//')

  local has_listen=false
  if (( fzf_version > 0 )) || (( fzf_version == 0 && fzf_minor >= 30 )); then
    has_listen=true
  fi

  # Temp files for data exchange
  local tmpdir="${TMPDIR:-/tmp}"
  local data_file=$(mktemp "${tmpdir}/wt-data.XXXXXX")
  local remote_file=$(mktemp "${tmpdir}/wt-remote.XXXXXX")
  local fzf_out=$(mktemp "${tmpdir}/wt-fzf.XXXXXX")
  local mode_file=$(mktemp "${tmpdir}/wt-mode.XXXXXX")
  echo "$initial_mode" > "$mode_file"

  # Format initial data based on mode
  local formatted
  if [[ "$initial_mode" == "uproot" ]]; then
    formatted=$(_wt_format_uproot "$raw_local")
  elif [[ "$initial_mode" == "plant" ]]; then
    formatted=$(wt-core unified --branches 2>/dev/null)
  else
    formatted=$(_wt_format_browse "$raw_local")
  fi

  # Find a free port for fzf --listen
  local listen_port=""
  local listen_arg=""
  if $has_listen; then
    listen_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo "")
    if [[ -n "$listen_port" ]]; then
      listen_arg="--listen=localhost:${listen_port}"
    fi
  fi

  # Background: fetch remote data and reload fzf
  local remote_pid=""
  if [[ -n "$listen_port" && "$initial_mode" != "plant" ]]; then
    (
      wt-core unified --remote 2>/dev/null > "$remote_file"
      if [[ -s "$remote_file" ]]; then
        local current_mode
        current_mode=$(<"$mode_file")
        local new_formatted
        if [[ "$current_mode" == "uproot" ]]; then
          new_formatted=$(_wt_format_uproot "$(<"$remote_file")")
        else
          new_formatted=$(_wt_format_browse "$(<"$remote_file")")
        fi
        # URL-encode the reload data
        local encoded
        encoded=$(printf '%s\n' "$new_formatted" | sed 's/%/%25/g; s/ /%20/g; s/\t/%09/g')
        # Use fzf's reload action via HTTP
        curl -s "localhost:${listen_port}" -d "reload(wt-core unified --remote 2>/dev/null | _wt_format_for_mode)" &>/dev/null 2>&1 || true
      fi
    ) &
    remote_pid=$!
  fi

  # Determine initial header and prompt
  local header prompt
  case "$initial_mode" in
    browse)
      header=$'\033[33m\u21bb Fetching remote info...\033[0m     /uproot \u00b7 /plant \u00b7 enter cd \u00b7 ctrl-o open'
      prompt="> "
      ;;
    uproot)
      header=$'\033[31m\u26a0 UPROOT MODE\033[0m  tab select \u00b7 enter confirm \u00b7 esc browse'
      prompt="uproot> "
      ;;
    plant)
      header="Select branch or [new branch]  \u00b7 esc browse"
      prompt="plant> "
      ;;
  esac

  # Preview command
  local preview_cmd='wt-core unified --preview {-1} 2>/dev/null'

  # Build fzf arguments
  local -a fzf_args=(
    --ansi
    --height=60%
    --delimiter=$'\t'
    --with-nth=1
    --header="$header"
    --prompt="$prompt"
    --preview="$preview_cmd"
    --preview-window=right:40%:wrap
    --expect=ctrl-o,ctrl-x
    --bind="tab:toggle+down"
  )

  if [[ -n "$listen_arg" ]]; then
    fzf_args+=("$listen_arg")
  fi

  if [[ "$initial_mode" == "uproot" ]]; then
    fzf_args+=(--multi)
  elif [[ "$initial_mode" == "plant" ]]; then
    # Plant mode: no preview, simple list
    fzf_args=(
      --ansi
      --height=40%
      --header="$header"
      --prompt="$prompt"
    )
  fi

  # Run fzf
  printf '%s\n' "${(@f)formatted}" | fzf "${fzf_args[@]}" > "$fzf_out"

  # Kill background fetch if still running
  [[ -n "$remote_pid" ]] && kill "$remote_pid" 2>/dev/null; wait "$remote_pid" 2>/dev/null

  # Process results
  [[ -s "$fzf_out" ]] || {
    rm -f "$data_file" "$remote_file" "$fzf_out" "$mode_file"
    return
  }

  local key selection abs_path
  key=$(head -1 "$fzf_out")

  if [[ "$initial_mode" == "plant" ]]; then
    # Plant mode: selection is the branch name
    selection=$(tail -1 "$fzf_out")
    rm -f "$data_file" "$remote_file" "$fzf_out" "$mode_file"
    _wt_handle_plant "$selection"
    return
  fi

  if [[ "$initial_mode" == "uproot" ]]; then
    # Uproot mode: multi-selection
    local -a selected_lines
    selected_lines=("${(@f)$(tail -n +2 "$fzf_out")}")
    rm -f "$data_file" "$remote_file" "$fzf_out" "$mode_file"
    _wt_handle_uproot "${selected_lines[@]}"
    return
  fi

  # Browse mode
  selection=$(tail -1 "$fzf_out")
  rm -f "$data_file" "$remote_file" "$fzf_out" "$mode_file"
  [[ -n "$selection" ]] || return

  abs_path=$(echo "$selection" | awk -F'\t' '{print $NF}')
  [[ -n "$abs_path" ]] || return

  case "$key" in
    ctrl-o) ${(z)WT_OPENER} "$abs_path" ;;
    ctrl-x) _wt_delete "$abs_path" ;;
    *)
      cd "$abs_path"
      # Run post-enter hook
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

    # Branch prefix enforcement (opinionated mode)
    local opinionated
    opinionated=$(git config --get wt.opinionated.branchPrefix 2>/dev/null)
    if [[ "$opinionated" == "true" ]]; then
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
    echo "Failed to create worktree: $target" >&2
    return 1
  fi

  echo "Created worktree: $selection -> $target"

  # Run post-plant hook
  _wt_run_hook "post-plant" "$target" "$selection" "true"

  # Auto-cd (check config)
  local auto_cd
  auto_cd=$(git config --get wt.opinionated.autoCd 2>/dev/null)
  if [[ "$auto_cd" == "true" ]]; then
    cd "$target"
  else
    printf "cd into %s? [Y/n] " "$target"
    local yn
    read -r yn
    if [[ "$yn" != [nN]* ]]; then
      cd "$target"
    fi
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
  if [[ "${WT_CLEAN_KEEP_BRANCHES:-0}" == "1" ]]; then
    keep_branches=true
  fi

  local delete_branch
  delete_branch=$(git config --get wt.opinionated.deleteBranch 2>/dev/null)
  if [[ "$delete_branch" == "true" ]]; then
    keep_branches=false
  fi

  local -a paths branches
  local line abs_path branch_name
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    abs_path=$(echo "$line" | awk -F'\t' '{print $NF}')
    # Extract branch from the formatted line (first non-space word)
    branch_name=$(echo "$line" | sed 's/^[[:space:]]*//' | awk '{print $1}' | sed $'s/\033\\[[0-9;]*m//g')
    [[ -n "$abs_path" && -n "$branch_name" ]] || continue
    paths+=("$abs_path")
    branches+=("$branch_name")
  done

  [[ ${#paths[@]} -gt 0 ]] || return

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
      echo "Failed to remove worktree: $branch" >&2
    fi
  done
}

# ---------------------------------------------------------------------------
# Legacy helpers (kept for backward compat)
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

  # Run post-plant hook
  _wt_run_hook "post-plant" "$target" "$1" "true"

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
# Tab completion
# ---------------------------------------------------------------------------
_wt() {
  { set +x } 2>/dev/null
  emulate -LR zsh

  local branch_icon=$'\ue725'
  local branch rel abs

  if [[ "$words[2]" == "add" || "$words[2]" == "plant" ]]; then
    local -a branches
    branches=(${(f)"$(wt-core completions 2>/dev/null)"})
    _describe 'branch' branches
    return
  fi

  local -a wt_descs subcmds
  subcmds=(
    "add:Create a new worktree (legacy)"
    "plant:Create a new worktree"
    "uproot:Review and bulk-delete stale worktrees"
    "clean:Alias for uproot"
  )
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(wt-core entries 2>/dev/null)
  _describe 'subcommand' subcmds -V subcommands
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt

} # end anonymous function
