Describe "_wt_entries"
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

  It "shows main worktree with relative path '.'"
    When call _wt_entries
    The output should include "	.	"
    The status should be success
  End

  It "includes additional worktree branch name in output"
    add_test_worktree "$TEST_REPO" "feature-x" >/dev/null
    When call _wt_entries
    The output should include "feature-x"
    The status should be success
  End

  It "produces correct line count for multiple worktrees"
    add_test_worktree "$TEST_REPO" "feat-a" >/dev/null
    add_test_worktree "$TEST_REPO" "feat-b" >/dev/null
    When call _wt_entries
    The lines of output should equal 3
  End

  It "extracts branch name without refs/heads/ prefix"
    When call _wt_entries
    The first line of output should start with "main	"
  End

  It "shows (detached) for detached HEAD"
    git -C "$TEST_REPO" checkout --detach --quiet
    When call _wt_entries
    The output should include "(detached)"
  End

  It "handles worktrees nested inside main worktree (.worktrees/)"
    add_nested_test_worktree "$TEST_REPO" "nested-feat" >/dev/null
    When call _wt_entries
    The output should include "nested-feat"
    The output should include ".worktrees/nested-feat"
    The lines of output should equal 2
  End

  It "handles many worktrees (sibling + nested)"
    add_test_worktree "$TEST_REPO" "feat-a" >/dev/null
    add_test_worktree "$TEST_REPO" "feat-b" >/dev/null
    add_nested_test_worktree "$TEST_REPO" "nested-c" >/dev/null
    add_nested_test_worktree "$TEST_REPO" "nested-d" >/dev/null
    When call _wt_entries
    The lines of output should equal 5
  End

  It "handles branch names with slashes"
    local target="$(dirname "$TEST_REPO")/fix-slash"
    git -C "$TEST_REPO" worktree add -b "fix/my-bug" "$target" --quiet 2>/dev/null
    When call _wt_entries
    The output should include "fix/my-bug"
  End

  It "returns empty output when not in a git repo"
    cd /tmp
    When call _wt_entries
    The output should equal ""
  End
End
