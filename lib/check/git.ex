defmodule Check.Git do
  @moduledoc "Helpers for resolving git diff ranges relative to the base branch."

  # SHA of git's empty tree object — used to diff a root commit that has no parent.
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  @doc """
  Git revision range (as diff args) for committed changes relative to `base_branch`.

  Three-dot `base...HEAD` collapses to nothing when the current branch *is* the
  base branch, so running on `main` would never report any changes. On the base
  branch we instead compare against the latest commit.

    - feature branch: `base...HEAD` (commits made since the base branch)
    - base branch: `HEAD~1...HEAD` (the latest commit), or the empty tree on a root commit

  Working-tree/uncommitted changes are never included.

  ## Examples

      iex> Check.Git.committed_diff_range("main")
      ["main...HEAD"]
  """
  @spec committed_diff_range(String.t()) :: [String.t()]
  def committed_diff_range(base_branch) do
    if current_branch() == base_branch do
      if parent_commit?(), do: ["HEAD~1...HEAD"], else: [@empty_tree, "HEAD"]
    else
      ["#{base_branch}...HEAD"]
    end
  end

  @doc "Name of the currently checked-out branch, or `nil` if it cannot be resolved."
  @spec current_branch() :: String.t() | nil
  def current_branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  @doc "True when `HEAD` has a parent commit (i.e. it is not the root commit)."
  @spec parent_commit?() :: boolean()
  def parent_commit? do
    match?(
      {_, 0},
      System.cmd("git", ["rev-parse", "--verify", "--quiet", "HEAD~1"], stderr_to_stdout: true)
    )
  end

  @doc """
  Returns the short SHA of HEAD, or `nil` if it cannot be resolved.

  ## Examples

      iex> is_binary(Check.Git.head_sha())
      true
  """
  @spec head_sha() :: String.t() | nil
  def head_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end
end
