# git-worktree-switcher - quickly switch between git worktrees using fzf

# Editor used by ctrl-o in the fzf picker (supports multi-word commands)
: ${WT_OPENER:=code}

# Parse `git worktree list --porcelain` into tab-delimited rows:
#   branch_name \t relative_path \t absolute_path
# The main worktree's relative path is shown as "."
_wt_entries() {
  local line wt_path wt_branch main_path rel
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        if [[ -n "$wt_path" ]]; then
          [[ "$wt_path" == "$main_path" ]] && rel="." || rel="${wt_path#$main_path/}"
          printf '%s\t%s\t%s\n' "$wt_branch" "$rel" "$wt_path"
        fi
        wt_path="${line#worktree }"
        [[ -z "$main_path" ]] && main_path="$wt_path"
        wt_branch=""
        ;;
      branch\ *)
        wt_branch="${line#branch refs/heads/}"
        ;;
      HEAD\ *)
        [[ -z "$wt_branch" ]] && wt_branch="(detached)"
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  # Emit last entry
  if [[ -n "$wt_path" ]]; then
    [[ "$wt_path" == "$main_path" ]] && rel="." || rel="${wt_path#$main_path/}"
    printf '%s\t%s\t%s\n' "$wt_branch" "$rel" "$wt_path"
  fi
}

# Returns the absolute path of the main (first) worktree
_wt_main_worktree() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}'
}

# Returns the branch name of the main worktree (e.g., "main" or "master")
_wt_default_branch() {
  git worktree list --porcelain 2>/dev/null | awk '
    /^branch / {
      b = substr($0, 8)
      sub("refs/heads/", "", b)
      print b
      exit
    }
  '
}

# Returns 0 if worktree has uncommitted/untracked changes, 1 if clean
_wt_has_changes() {
  local wt_path="$1"
  [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]
}

# Returns the number of commits on <branch> not on the default branch.
# Accepts optional second arg to avoid redundant _wt_default_branch calls.
_wt_unique_commits() {
  local branch="$1"
  local default_branch="${2:-$(_wt_default_branch)}"
  git log --oneline "$default_branch..$branch" 2>/dev/null | wc -l | tr -d ' '
}

# Returns 0 if the remote tracking branch is gone, 1 if it still exists
_wt_remote_branch_gone() {
  local branch="$1"
  ! git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null
}

# Returns 0 if gh CLI is installed and authed for current repo, 1 otherwise.
# Prints a tip to stderr if gh is missing or unauthed.
_wt_gh_available() {
  if ! command -v gh &>/dev/null; then
    echo "tip: brew install gh for PR merge detection" >&2
    return 1
  fi
  if ! gh auth token &>/dev/null; then
    echo "tip: run 'gh auth login' to enable PR status checks" >&2
    return 1
  fi
  return 0
}

# Returns 0 if a merged PR exists for the given branch, 1 otherwise.
# Outputs the PR number if found (e.g., "42").
_wt_pr_merged() {
  local branch="$1"
  _wt_gh_available 2>/dev/null || return 1
  local pr_number
  pr_number=$(gh pr list --head "$branch" --state merged --json number --jq '.[0].number' 2>/dev/null)
  [[ -n "$pr_number" ]] && echo "$pr_number" && return 0
  return 1
}

# Fetches all merged PRs for the current repo in a single GraphQL call.
# Populates the associative array _wt_merged_prs: branch_name -> PR number.
# Returns 1 if gh is unavailable.
_wt_fetch_merged_prs() {
  typeset -gA _wt_merged_prs
  _wt_merged_prs=()
  _wt_gh_available 2>/dev/null || return 1

  local owner repo remote_url
  remote_url=$(git remote get-url origin 2>/dev/null) || return 1
  # Extract owner/repo from git@host:owner/repo.git or https://host/owner/repo.git
  if [[ "$remote_url" == git@* ]]; then
    local path_part="${remote_url#*:}"
    owner="${path_part%%/*}"
    repo="${${path_part#*/}%.git}"
  else
    local path_part="${remote_url#https://*/}"
    owner="${path_part%%/*}"
    repo="${${path_part#*/}%.git}"
  fi
  [[ -z "$owner" || -z "$repo" ]] && return 1

  local branch_name pr_number
  while IFS=$'\t' read -r branch_name pr_number; do
    [[ -n "$branch_name" ]] && _wt_merged_prs[$branch_name]="$pr_number"
  done < <(gh api graphql \
    -f query='query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){pullRequests(first:100,states:MERGED,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{headRefName number}}}}' \
    -f owner="$owner" -f repo="$repo" \
    --jq '.data.repository.pullRequests.nodes[] | [.headRefName, (.number | tostring)] | @tsv' 2>/dev/null)
}

# Checks a single worktree and outputs a tab-delimited verdict line.
# Args: branch_name abs_path gh_mode("gh" or "no-gh") [default_branch]
# Output: verdict\tbranch\tpath\tevidence
_wt_check_worktree() {
  local branch="$1" wt_path="$2" gh_mode="$3" default_branch="${4:-$(_wt_default_branch)}"
  local evidence=()
  local has_gone_signal=false
  local has_concerns=false

  # Signal: PR merged (lookup from pre-fetched associative array)
  if [[ "$gh_mode" == "gh" ]] && [[ -n "${_wt_merged_prs[$branch]:-}" ]]; then
    evidence+=("PR #${_wt_merged_prs[$branch]} merged")
    has_gone_signal=true
  fi

  # Signal: remote branch gone
  if _wt_remote_branch_gone "$branch"; then
    evidence+=("remote gone")
    has_gone_signal=true
  fi

  # Signal: unique commits
  local ahead
  ahead=$(_wt_unique_commits "$branch" "$default_branch")
  if [[ "$ahead" -gt 0 ]]; then
    evidence+=("${ahead} commit(s) ahead")
    has_concerns=true
  fi

  # Signal: uncommitted changes
  if _wt_has_changes "$wt_path"; then
    evidence+=("uncommitted changes")
    has_concerns=true
  else
    evidence+=("clean")
  fi

  # Verdict: safe only if no concerns AND (remote gone or PR merged)
  local verdict="warn"
  if ! $has_concerns && $has_gone_signal; then
    verdict="safe"
  fi

  local evidence_str="${(j: · :)evidence}"
  printf "%s\t%s\t%s\t%s\n" "$verdict" "$branch" "$wt_path" "$evidence_str"
}

# Quick local-only staleness check for a worktree.
# Returns: "safe", "warn", or "" (unknown)
_wt_quick_status() {
  local branch="$1" wt_path="$2" default_branch="${3:-$(_wt_default_branch)}"

  [[ "$branch" == "(detached)" ]] && return

  local remote_gone=false
  _wt_remote_branch_gone "$branch" && remote_gone=true

  local ahead
  ahead=$(_wt_unique_commits "$branch" "$default_branch")

  local dirty=false
  _wt_has_changes "$wt_path" && dirty=true

  if $remote_gone && [[ "$ahead" -eq 0 ]] && ! $dirty; then
    echo "safe"
  elif [[ "$ahead" -gt 0 ]] || $dirty; then
    echo "warn"
  fi
}

_wt_clean() {
  local keep_branches=false no_gh=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --keep-branches) keep_branches=true ;;
      --no-gh)         no_gh=true ;;
    esac
  done
  [[ "${WT_CLEAN_KEEP_BRANCHES:-0}" == "1" ]] && keep_branches=true

  # Pre-flight: check gh availability (prints tips to stderr)
  local gh_mode="no-gh"
  if ! $no_gh && _wt_gh_available; then
    gh_mode="gh"
  fi

  # Freshen remote state (background) while we fetch merged PRs (foreground)
  echo "Fetching latest remote state..."
  git fetch --prune --quiet 2>/dev/null &
  local fetch_pid=$!
  if [[ "$gh_mode" == "gh" ]]; then
    _wt_fetch_merged_prs
  fi
  wait $fetch_pid

  # Gather verdicts for all non-main worktrees
  local main_wt default_branch
  main_wt=$(_wt_main_worktree)
  default_branch=$(_wt_default_branch)
  local verdicts=()
  local raw=$(_wt_entries)

  # Collect worktree pairs first, then check each outside the read loop
  local -a wt_pairs
  local branch rel abs
  while IFS=$'\t' read -r branch rel abs; do
    [[ "$abs" == "$main_wt" ]] && continue
    [[ "$branch" == "(detached)" ]] && continue
    wt_pairs+=("$branch"$'\t'"$abs")
  done <<< "$raw"

  local pair
  for pair in "${wt_pairs[@]}"; do
    IFS=$'\t' read -r branch abs <<< "$pair"
    verdicts+=("$(_wt_check_worktree "$branch" "$abs" "$gh_mode" "$default_branch")")
  done

  if [[ ${#verdicts[@]} -eq 0 ]]; then
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
  for v in "${verdicts[@]}"; do
    IFS=$'\t' read -r verdict branch _ _ <<< "$v"
    (( ${#branch} > max_branch_width )) && max_branch_width=${#branch}
  done

  for v in "${verdicts[@]}"; do
    IFS=$'\t' read -r verdict branch wt_path evidence <<< "$v"

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
  done

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
  local wt_path branch
  for i in {1..${#paths[@]}}; do
    wt_path="${paths[$i]}"
    branch="${branches[$i]}"

    if [[ "$PWD" == "$wt_path"* ]]; then
      cd "$main_wt"
    fi

    if git worktree remove "$wt_path" 2>/dev/null; then
      echo "Removed worktree: $branch"
      if ! $keep_branches; then
        git branch -D "$branch" 2>/dev/null && echo "Deleted branch: $branch"
      fi
    else
      echo "Failed to remove worktree: $branch (may have changes -- use git worktree remove --force)" >&2
    fi
  done
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
  local main_wt="$(_wt_main_worktree)"
  local target="$(dirname "$main_wt")/$name"

  # Use existing branch if it exists, otherwise create a new one with -b
  if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
    git worktree add "$target" "$name" || return 1
  else
    git worktree add -b "$name" "$target" || return 1
  fi

  cd "$target"

  printf "Open in %s? [Y/n] " "$WT_OPENER"
  local open_yn
  read -r open_yn
  if [[ "$open_yn" != [nN]* ]]; then
    ${(z)WT_OPENER} "$target"
  fi
}

# Remove a worktree by absolute path, with a confirmation prompt.
# Safely handles the case where the user is cd'd into the worktree
# being deleted by moving them to the main worktree first.
_wt_delete() {
  local wt_path="$1"
  local name="$(basename "$wt_path")"

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
  wt                  Open fzf worktree picker (alias: list, ls, l)
  wt <path>           Switch to worktree at path
  wt add <branch>     Create new worktree (and branch if needed)
  wt clean            Review and batch-delete stale worktrees (alias: c)
    --no-gh            Skip gh CLI checks (merged PR detection)
    --keep-branches    Keep local branches after removing worktrees

fzf keybindings:
  enter    Switch to selected worktree
  ctrl-a   Create new worktree
  ctrl-o   Open in editor ($WT_OPENER, default: code)
  ctrl-x   Delete worktree (with confirmation)
  ctrl-g   Open cleanup helper (wt clean)
EOF
    return
  fi

  if [[ "$1" == "clean" || "$1" == "c" ]]; then
    _wt_clean "${@:2}"
    return
  fi

  if [[ "$1" == "add" ]]; then
    _wt_add "${@:2}"
    return
  fi

  # list/ls/l fall through to the interactive picker
  if [[ "$1" == "list" || "$1" == "ls" || "$1" == "l" ]]; then
    shift
  fi

  # Direct path: `wt some/path` cds straight there
  if [[ -n "$1" ]]; then
    local main_wt="$(_wt_main_worktree)"
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
  local -a fzf_lines
  while IFS=$'\t' read -r branch rel abs; do
    fzf_lines+=("$(printf "%s %-${max_width}s  %s %s\t%s" \
      "$branch_icon" "$branch" "$folder" "$rel" "$abs")")
  done <<< "$raw"

  local result=$(printf '%s\n' "${fzf_lines[@]}" | fzf --height=40% --delimiter='\t' --with-nth=1 \
    --header="enter:switch │ ctrl-a:add │ ctrl-o:open │ ctrl-x:delete │ ctrl-g:clean" \
    --expect=ctrl-o,ctrl-x,ctrl-a,ctrl-g)

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
      [[ -n "$branch_name" ]] && _wt_add "$branch_name"
      ;;
    ctrl-o) ${(z)WT_OPENER} "$abs_path" ;;
    ctrl-x) _wt_delete "$abs_path" ;;
    ctrl-g) _wt_clean ;;
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
  subcmds=("add:Create a new worktree" "clean:Review and delete stale worktrees" "c:Alias for clean" "list:Open fzf picker" "ls:Alias for list" "l:Alias for list")
  while IFS=$'\t' read -r branch rel abs; do
    wt_descs+=("${rel//:/\\:}:$branch_icon $branch")
  done < <(_wt_entries)
  _describe 'subcommand' subcmds -V subcommands
  _describe 'worktree' wt_descs -V worktrees
}
compdef _wt wt
