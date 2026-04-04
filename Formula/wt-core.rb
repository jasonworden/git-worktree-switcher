class WtCore < Formula
  desc "Fast git worktree manager (core binary)"
  homepage "https://github.com/jasonworden/git-worktree-switcher"
  license "MIT"
  head "https://github.com/jasonworden/git-worktree-switcher.git", branch: "main"

  depends_on "rust" => :build

  def install
    cd "rust" do
      system "cargo", "install", *std_cargo_args
    end
  end

  test do
    assert_match "Fast git worktree manager", shell_output("#{bin}/wt-core --help")
  end
end
