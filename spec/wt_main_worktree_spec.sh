Describe "_wt_main_worktree"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
  }

  cleanup() {
    cleanup_test_repo "$TEST_REPO"
  }

  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns absolute path of main worktree"
    When call _wt_main_worktree
    The output should equal "$TEST_REPO"
    The status should be success
  End

  It "has no trailing slash"
    When call _wt_main_worktree
    The output should not end with "/"
  End

  It "returns empty output when not in a git repo"
    cd /tmp
    When call _wt_main_worktree
    The output should equal ""
  End
End
