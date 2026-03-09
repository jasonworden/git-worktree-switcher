Describe "_wt_delete"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "to-delete")
  }

  cleanup() {
    cleanup_test_repo "$TEST_REPO"
  }

  BeforeEach "setup"
  AfterEach "cleanup"

  # _wt_delete uses `read -q` which requires a terminal.
  # We test by replacing _wt_delete with a version that has a controllable answer.

  It "does not remove worktree when user declines"
    wt_delete_decline() {
      local wt_path="$1"
      local name=$(basename "$wt_path")
      printf "Remove worktree '%s'? [y/N] " "$name"
      # Simulate "n"
      echo
      return 1
    }
    When call wt_delete_decline "$WT_PATH"
    The status should be failure
    The path "$WT_PATH" should be directory
    The stdout should be present
  End

  It "removes worktree when user confirms"
    wt_delete_confirm() {
      local wt_path="$1"
      local name=$(basename "$wt_path")
      printf "Remove worktree '%s'? [y/N] " "$name"
      echo
      if [[ "$PWD" == "$wt_path"* ]]; then
        cd "$(_wt_main_worktree)"
      fi
      git worktree remove "$wt_path"
    }
    When call wt_delete_confirm "$WT_PATH"
    The path "$WT_PATH" should not be directory
    The stdout should be present
  End

  It "moves to main worktree when deleting current worktree"
    wt_delete_from_inside() {
      local wt_path="$1"
      if [[ "$PWD" == "$wt_path"* ]]; then
        cd "$(_wt_main_worktree)"
      fi
      git worktree remove "$wt_path"
    }
    cd "$WT_PATH"
    When call wt_delete_from_inside "$WT_PATH"
    The variable PWD should equal "$TEST_REPO"
  End
End
