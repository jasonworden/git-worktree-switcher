Describe "wt-core default-branch"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns main when default branch is main"
    When call wt-core default-branch
    The output should equal "main"
    The status should be success
  End
End

Describe "wt-core quick-status"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns safe for clean worktree with no remote branch"
    When call wt-core quick-status "feature-x" "$WT_PATH"
    The output should equal "safe"
    The status should be success
  End

  It "returns warn for worktree with uncommitted changes"
    echo "dirty" > "$WT_PATH/newfile.txt"
    When call wt-core quick-status "feature-x" "$WT_PATH"
    The output should equal "warn"
  End

  It "returns warn for worktree with unique commits"
    git -C "$WT_PATH" commit --allow-empty -m "unique1" --quiet
    When call wt-core quick-status "feature-x" "$WT_PATH"
    The output should equal "warn"
  End
End

Describe "wt-core clean-check"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "outputs safe verdict for clean worktree with no remote"
    When call wt-core clean-check
    The output should include "safe"
    The output should include "remote gone"
    The status should be success
  End

  It "outputs warning for worktree with uncommitted changes"
    echo "dirty" > "$WT_PATH/file.txt"
    When call wt-core clean-check
    The output should include "warn"
    The output should include "uncommitted changes"
  End

  It "outputs warning for worktree with unique commits"
    git -C "$WT_PATH" commit --allow-empty -m "unique" --quiet
    When call wt-core clean-check
    The output should include "warn"
    The output should include "commit"
  End
End

Describe "wt-core gh-available"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "returns 1 when gh is not installed"
    PATH="/usr/bin:/bin:$SHELLSPEC_PROJECT_ROOT/rust/target/debug"
    When call wt-core gh-available
    The status should be failure
  End
End
