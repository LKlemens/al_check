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
    log_committed_only(base_branch)

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

        clean_coverdata()
        port = Check.Port.open("mix", args)
        {status, output} = Check.Runner.stream_and_capture_port(port)
        # ignore coverage threshold failure — we show modified coverage separately
        status = if Check.Failed.coverage_threshold_failure?(output), do: 0, else: status
        if status == 0, do: Check.Coverage.maybe_merge_and_show_modified()
        {status, output}
    end
  end

  defp extra_args(opts) do
    test_args = if opts[:test_args], do: String.split(opts[:test_args]), else: []
    repeat = if opts[:repeat], do: ["--repeat-until-failure", to_string(opts[:repeat])], else: []
    cover = if coverage_enabled?(), do: ["--cover", "--export-coverage", "modified"], else: []
    (test_args -- ["--cover"]) ++ repeat ++ cover
  end

  defp clean_coverdata do
    Path.wildcard("cover/*.coverdata") |> Enum.each(&File.rm/1)
  end

  defp coverage_enabled? do
    case Check.Config.load() do
      {:ok, config} -> Check.Config.parse_coverage(config["coverage"]).mod != false
      _ -> false
    end
  end

  defp load_config do
    case Check.Config.load() do
      {:ok, config} -> config
      _ -> %{}
    end
  end

  defp log_committed_only(base_branch) do
    IO.puts([
      IO.ANSI.format([
        :light_black,
        "  Note: only committed changes vs #{base_branch} are considered; uncommitted/working-tree changes are ignored"
      ])
    ])
  end

  defp get_modified_test_files(base_branch) do
    range = Check.Git.committed_diff_range(base_branch)

    case System.cmd(
           "git",
           ["diff", "--name-only", "--diff-filter=d"] ++ range ++ ["--", "test/**/*_test.exs"],
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
