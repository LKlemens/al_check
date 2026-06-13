defmodule Check.GitTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :verify_on_exit!

  alias Check.Git

  describe "committed_diff_range/1" do
    test "uses base...HEAD on a feature branch" do
      stub(System, :cmd, fn "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts ->
        {"feature\n", 0}
      end)

      assert Git.committed_diff_range("main") == ["main...HEAD"]
    end

    test "uses HEAD~1...HEAD when on the base branch with a parent commit" do
      stub(System, :cmd, fn
        "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"main\n", 0}
        "git", ["rev-parse", "--verify", "--quiet", "HEAD~1"], _opts -> {"sha\n", 0}
      end)

      assert Git.committed_diff_range("main") == ["HEAD~1...HEAD"]
    end

    test "falls back to the empty tree on a root commit on the base branch" do
      stub(System, :cmd, fn
        "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"main\n", 0}
        "git", ["rev-parse", "--verify", "--quiet", "HEAD~1"], _opts -> {"", 128}
      end)

      assert [empty_tree, "HEAD"] = Git.committed_diff_range("main")
      assert String.length(empty_tree) == 40
    end
  end
end
