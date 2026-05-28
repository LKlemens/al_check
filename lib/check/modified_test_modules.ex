defmodule CheckEscript.ModifiedTestModules do
  @moduledoc "Runs whole test files that were added or modified on the current branch."

  def run(test_opts \\ %{}) do
    config = load_config()
    base_branch = CheckEscript.Config.base_branch(config)
    files = get_modified_test_files(base_branch)

    if Enum.empty?(files) do
      IO.puts("No modified test files on this branch")
      {0, ""}
    else
      args = ["test" | files] ++ extra_args(test_opts)

      Enum.each(files, fn f -> IO.puts([IO.ANSI.format([:cyan, "  #{f}"])]) end)

      extra_str = Enum.join(extra_args(test_opts), " ")
      IO.puts([IO.ANSI.format([:cyan, "\nTest command: mix test [#{length(files)} modules] #{extra_str}\n"])])

      port = CheckEscript.Port.open("mix", args)
      status = CheckEscript.Runner.stream_port_output(port)
      {status, ""}
    end
  end

  defp extra_args(opts) do
    test_args = if opts[:test_args], do: String.split(opts[:test_args]), else: []
    repeat = if opts[:repeat], do: ["--repeat-until-failure", to_string(opts[:repeat])], else: []
    test_args ++ repeat
  end

  defp load_config do
    case CheckEscript.Config.load() do
      {:ok, config} -> config
      _ -> %{}
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
