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

  It "rejects bare arguments (use the picker, not wt <path>)"
    When run wt "does-not-exist"
    The status should be failure
    The stderr should include "unknown command"
  End

  It "rejects wt . (no direct cd shortcut)"
    When run wt .
    The status should be failure
    The stderr should include "unknown command"
  End

  It "rejects absolute path as first arg even if it is a worktree"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "my-feature")
    When run wt "$WT_PATH"
    The status should be failure
    The stderr should include "unknown command"
  End
End
