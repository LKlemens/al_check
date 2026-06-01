defmodule Check.ModifiedTestModules do
  @moduledoc "Runs whole test files that were added or modified on the current branch."

  def run(test_opts \\ %{}) do
    config = load_config()

    case Check.Config.base_branch(config, warn: true, log: true) do
      nil ->
        {1, "Could not detect base branch. Set \"base_branch\" in .check.json"}

      base_branch ->
        run_with_branch(base_branch, test_opts)
    end
  end

  defp run_with_branch(base_branch, test_opts) do
    case get_modified_test_files(base_branch) do
      {:error, msg} ->
        {1, msg}

      {:ok, []} ->
        IO.puts("No modified test files on this branch")
        {0, ""}

      {:ok, files} ->
        args = ["test" | files] ++ extra_args(test_opts)

        Enum.each(files, fn f -> IO.puts([IO.ANSI.format([:cyan, "  #{f}"])]) end)

        extra_str = Enum.join(extra_args(test_opts), " ")

        IO.puts([
          IO.ANSI.format([
            :cyan,
            "\nTest command: mix test [#{length(files)} modules] #{extra_str}\n"
          ])
        ])

        port = Check.Port.open("mix", args)
        status = Check.Runner.stream_port_output(port)
        {status, ""}
    end
  end

  defp extra_args(opts) do
    test_args = if opts[:test_args], do: String.split(opts[:test_args]), else: []
    repeat = if opts[:repeat], do: ["--repeat-until-failure", to_string(opts[:repeat])], else: []
    test_args ++ repeat
  end

  defp load_config do
    case Check.Config.load() do
      {:ok, config} -> config
      _ -> %{}
    end
  end

  defp get_modified_test_files(base_branch) do
    case System.cmd(
           "git",
           [
             "diff",
             "--name-only",
             "--diff-filter=d",
             "#{base_branch}...",
             "--",
             "test/**/*_test.exs"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.filter(&File.exists?/1)}

      {error, _} ->
        msg = "git diff failed: #{String.trim(error)}"
        IO.puts([IO.ANSI.format([:red, msg])])
        {:error, msg}
    end
  end
end
