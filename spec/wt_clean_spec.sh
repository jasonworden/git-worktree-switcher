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

Describe "_wt_has_changes"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 1 (false) for a clean worktree"
    When call _wt_has_changes "$TEST_REPO"
    The status should be failure
  End

  It "returns 0 (true) when there are uncommitted changes"
    echo "dirty" > "$TEST_REPO/newfile.txt"
    When call _wt_has_changes "$TEST_REPO"
    The status should be success
  End
End

Describe "_wt_unique_commits"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 0 when branch has no unique commits"
    When call _wt_unique_commits "feature-x"
    The output should equal "0"
  End

  It "returns count of unique commits ahead of default branch"
    git -C "$WT_PATH" commit --allow-empty -m "unique1" --quiet
    git -C "$WT_PATH" commit --allow-empty -m "unique2" --quiet
    When call _wt_unique_commits "feature-x"
    The output should equal "2"
  End
End

Describe "_wt_remote_branch_gone"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
    REMOTE_DIR=$(create_test_remote "$TEST_REPO")
  }

  cleanup() {
    rm -rf "$REMOTE_DIR"
    cleanup_test_repo "$TEST_REPO"
  }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 0 (true) when remote branch does not exist"
    When call _wt_remote_branch_gone "nonexistent-branch"
    The status should be success
  End

  It "returns 1 (false) when remote branch exists"
    git -C "$TEST_REPO" push --quiet origin main:feature-branch 2>/dev/null
    git -C "$TEST_REPO" fetch --quiet 2>/dev/null
    When call _wt_remote_branch_gone "feature-branch"
    The status should be failure
  End
End

Describe "_wt_gh_available"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 1 when gh is not installed"
    PATH="/usr/bin:/bin"
    When call _wt_gh_available
    The status should be failure
    The stderr should include "tip:"
  End
End

Describe "_wt_pr_merged"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    source "$PLUGIN_PATH"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 1 when gh is not available"
    PATH="/usr/bin:/bin"
    When call _wt_pr_merged "any-branch"
    The status should be failure
  End
End
