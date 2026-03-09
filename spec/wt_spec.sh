Describe "wt"
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

  It "errors when not in a git repo"
    cd /tmp
    When run wt
    The stderr should include "Not a git repository"
    The status should be failure
  End

  It "shows usage with -h"
    When call wt -h
    The output should include "Usage:"
  End

  It "shows usage with --help"
    When call wt --help
    The output should include "Usage:"
  End

  Describe "wt . (regression test)"
    It "switches to main worktree absolute path"
      When call wt .
      The variable PWD should equal "$TEST_REPO"
      The status should be success
    End

    It "switches to main worktree from a different worktree"
      WT_PATH=$(add_test_worktree "$TEST_REPO" "other-branch")
      cd "$WT_PATH"
      When call wt .
      The variable PWD should equal "$TEST_REPO"
      The status should be success
    End
  End

  It "switches to an existing directory by absolute path"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "my-feature")
    When call wt "$WT_PATH"
    The variable PWD should equal "$WT_PATH"
    The status should be success
  End

  It "fails for nonexistent path"
    When run wt "does-not-exist"
    The status should be failure
    The stderr should be present
  End
End
