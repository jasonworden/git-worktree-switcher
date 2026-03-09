Describe "_wt_add"
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

  It "errors with no arguments"
    When run _wt_add
    The stderr should include "Usage"
    The status should be failure
  End

  It "creates a new worktree and branch"
    Data "n"
    When call _wt_add "new-feature"
    The variable PWD should equal "$(dirname "$TEST_REPO")/new-feature"
    The status should be success
    The stdout should include "Open in"
    The stderr should be present
  End

  It "checks out an existing branch into a new worktree"
    git -C "$TEST_REPO" branch existing-branch
    Data "n"
    When call _wt_add "existing-branch"
    The variable PWD should equal "$(dirname "$TEST_REPO")/existing-branch"
    The status should be success
    The stdout should be present
    The stderr should be present
  End

  It "creates worktree as sibling of main worktree"
    Data "n"
    When call _wt_add "sibling-test"
    The variable PWD should start with "$(dirname "$TEST_REPO")/"
    The status should be success
    The stdout should be present
    The stderr should be present
  End

  It "fails when branch is already checked out"
    Data "n"
    When run _wt_add "main"
    The status should be failure
    The stderr should be present
  End
End
