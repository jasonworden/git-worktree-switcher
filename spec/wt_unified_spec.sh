Describe "wt-core unified --local"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "outputs TSV with 10 fields per worktree"
    When call wt-core unified --local
    The first line of output should match pattern "*	*	*	*	*	*	*	*	*	*"
    The status should be success
  End

  It "marks first worktree as main (is_main=true)"
    When call wt-core unified --local
    The first line of output should include "pinned	true"
  End

  It "shows placeholder dots for remote columns in local mode"
    When call wt-core unified --local
    The first line of output should include "··"
  End

  It "shows pinned verdict for main worktree"
    When call wt-core unified --local
    The first line of output should include "pinned"
  End

  It "shows pending verdict for non-main worktree"
    add_test_worktree "$TEST_REPO" "feature-x" >/dev/null
    When call wt-core unified --local
    The second line of output should include "pending"
  End

  It "detects dirty worktree"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
    echo "dirty" > "$WT_PATH/newfile.txt"
    When call wt-core unified --local
    The second line of output should include "dirty"
  End

  It "counts unique commits ahead"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
    git -C "$WT_PATH" commit --allow-empty -m "unique1" --quiet
    git -C "$WT_PATH" commit --allow-empty -m "unique2" --quiet
    When call wt-core unified --local
    The second line of output should include "2"
  End

  It "matches worktree count"
    add_test_worktree "$TEST_REPO" "feature-x" >/dev/null
    add_test_worktree "$TEST_REPO" "fix-bug" >/dev/null
    When call wt-core unified --local
    The lines of output should equal 3
  End
End

Describe "wt-core unified --local --format=browse"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "outputs ANSI-colored text"
    When call wt-core unified --local --format=browse
    # ANSI escape codes contain [0m reset sequences
    The first line of output should include "[0m"
  End

  It "includes abs path as tab-delimited last field"
    When call wt-core unified --local --format=browse
    The first line of output should include "$TEST_REPO"
  End
End

Describe "wt-core unified --remote"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
    WT_PATH=$(add_test_worktree "$TEST_REPO" "feature-x")
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "fills remote columns (no more placeholder dots)"
    When call wt-core unified --remote
    The second line of output should not include "··"
  End

  It "shows keep verdict for worktree with no remote configured"
    When call wt-core unified --remote
    The second line of output should include "keep"
    The second line of output should include "no remote"
  End

  It "shows unsafe verdict for dirty worktree with no remote"
    echo "dirty" > "$WT_PATH/file.txt"
    When call wt-core unified --remote
    The second line of output should include "unsafe"
    The second line of output should include "dirty"
  End

  It "shows safe verdict when remote branch is gone"
    REMOTE_DIR=$(create_test_remote "$TEST_REPO")
    # Push the feature branch, then delete it on remote
    git -C "$TEST_REPO" push origin feature-x --quiet 2>/dev/null
    git -C "$REMOTE_DIR" branch -D feature-x 2>/dev/null
    git -C "$TEST_REPO" fetch --prune --quiet 2>/dev/null
    When call wt-core unified --remote
    The second line of output should include "safe"
    The second line of output should include "gone"
  End
End

Describe "wt-core unified --preview"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    cd "$TEST_REPO"
  }

  cleanup() { cleanup_test_repo "$TEST_REPO"; }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "shows branch name and last touched"
    When call wt-core unified --preview "$TEST_REPO"
    The output should include "main"
    The output should include "last touched"
  End
End

Describe "wt-core unified --branches"
  Include "$SHELLSPEC_PROJECT_ROOT/spec/spec_helper.sh"

  setup() {
    TEST_REPO=$(create_test_repo)
    REMOTE_DIR=$(create_test_remote "$TEST_REPO")
    cd "$TEST_REPO"
  }

  cleanup() {
    cleanup_test_repo "$TEST_REPO"
    rm -rf "$REMOTE_DIR"
  }
  BeforeEach "setup"
  AfterEach "cleanup"

  It "shows [new branch] as first option"
    When call wt-core unified --branches
    The first line of output should equal "[new branch]"
  End
End
