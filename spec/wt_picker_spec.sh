Describe "wt-core picker"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() {
    cleanup_test_repo "$TEST_REPO"
  }

  BeforeEach "setup"
  AfterEach "cleanup"

  It "outputs four tab-separated fields per worktree"
    When call wt-core picker
    The first line of output should match pattern "*	*	*	*"
    The status should be success
  End

  It "matches entries line count"
    add_test_worktree "$TEST_REPO" "feature-x" >/dev/null
    When call wt-core picker
    The lines of output should equal 2
  End

  It "first row is main with relative path ."
    When call wt-core picker
    The first line of output should start with "main	."
    The first line of output should include "${TEST_REPO}"
    The status should be success
  End

  It "returns empty output when not in a git repo"
    cd /tmp
    When call wt-core picker
    The output should equal ""
  End
End
