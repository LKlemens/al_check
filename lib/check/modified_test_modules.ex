defmodule CheckEscript.ModifiedTestModules do
  @moduledoc "Runs whole test files that were added or modified on the current branch."

  def run do
    base_branch = load_base_branch()
    files = get_modified_test_files(base_branch)

    if Enum.empty?(files) do
      IO.puts("No modified test files on this branch")
      0
    else
      IO.puts("Running:\n#{Enum.join(files, "\n")}")

      port = CheckEscript.Port.open("mix", ["test" | files])
      CheckEscript.Runner.stream_port_output(port)
    end
  end

  defp load_base_branch do
    case CheckEscript.Config.load() do
      {:ok, config} -> config["base_branch"] || "master"
      _ -> "master"
    end
  end

  defp get_modified_test_files(base_branch) do
    case System.cmd("git", ["diff", "--name-only", "--diff-filter=d", "#{base_branch}...", "--", "test/**/*_test.exs"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> Enum.filter(&File.exists?/1)

      {error, _} ->
        IO.puts([IO.ANSI.format([:red, "git diff failed: #{String.trim(error)}"])])
        []
    end
  end
end
