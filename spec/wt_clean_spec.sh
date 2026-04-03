Describe "_wt_default_branch"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns main when default branch is main"
    When call _wt_default_branch
    The output should equal "main"
    The status should be success
  End
End
