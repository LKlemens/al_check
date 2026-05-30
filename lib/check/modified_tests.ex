defmodule CheckEscript.ModifiedTests do
  @moduledoc """
  Detects modified tests on the current branch vs base branch.

  - If setup/setup_all/describe changed → runs the whole file
  - Otherwise → runs only the specific modified test lines
  """

  def run(test_opts \\ %{}) do
    config = load_config()
    base_branch = CheckEscript.Config.base_branch(config)
    modified_files = get_modified_test_files(base_branch)

    if Enum.empty?(modified_files) do
      IO.puts("No modified test files on this branch")
      {0, ""}
    else
      test_targets = Enum.flat_map(modified_files, &targets_for_file(&1, base_branch))
      run_tests(test_targets, test_opts)
    end
  end

  defp load_config do
    case CheckEscript.Config.load() do
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
        output |> String.split("\n", trim: true) |> Enum.filter(&File.exists?/1)

      {error, _} ->
        IO.puts([IO.ANSI.format([:red, "git diff failed: #{String.trim(error)}"])])
        []
    end
  end

  defp targets_for_file(file, base_branch) do
    changed_lines = get_changed_lines(file, base_branch)

    if Enum.empty?(changed_lines) do
      []
    else
      lines = File.read!(file) |> String.split("\n")
      classify_and_run(file, changed_lines, lines)
    end
  end

  defp classify_and_run(file, changed_lines, lines) do
    has_module_setup? =
      Enum.any?(changed_lines, fn line_num ->
        line = Enum.at(lines, line_num - 1, "")
        setup_line?(line) and find_enclosing_describe(lines, line_num) == nil
      end)

    if has_module_setup? do
      IO.puts([
        IO.ANSI.format([:yellow, "  #{file} (module-level setup changed, running whole file)"])
      ])

      [file]
    else
      targets =
        changed_lines
        |> Enum.map(fn line_num -> target_for_line(file, line_num, lines) end)
        |> List.flatten()
        |> Enum.uniq()

      if Enum.empty?(targets) do
        IO.puts([
          IO.ANSI.format([:yellow, "  #{file} (module-level change, running whole file)"])
        ])

        [file]
      else
        Enum.each(targets, fn t -> IO.puts([IO.ANSI.format([:cyan, "  #{t}"])]) end)
        targets
      end
    end
  end

  defp target_for_line(file, line_num, lines) do
    line = Enum.at(lines, line_num - 1, "")

    cond do
      setup_line?(line) -> target_from_describe(file, lines, line_num)
      String.match?(line, ~r/^\s*describe\b/) -> ["#{file}:#{line_num}"]
      true -> target_from_test_or_describe(file, lines, line_num)
    end
  end

  defp target_from_describe(file, lines, line_num) do
    case find_enclosing_describe(lines, line_num) do
      nil -> []
      desc_line -> ["#{file}:#{desc_line}"]
    end
  end

  defp target_from_test_or_describe(file, lines, line_num) do
    case find_enclosing_test(lines, line_num) do
      nil -> target_from_describe(file, lines, line_num)
      test_line -> ["#{file}:#{test_line}"]
    end
  end

  defp setup_line?(line), do: String.match?(line, ~r/^\s*(setup|setup_all)\b/)

  defp get_changed_lines(file, base_branch) do
    {output, _status} =
      System.cmd("git", ["diff", "-U0", "#{base_branch}...", "--", file], stderr_to_stdout: true)

    # Parse @@ hunk headers: @@ -old,count +new,count @@
    ~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
    |> Regex.scan(output)
    |> Enum.flat_map(fn
      [_, start, ""] ->
        [String.to_integer(start)]

      [_, start, count] ->
        s = String.to_integer(start)
        c = String.to_integer(count)
        if c == 0, do: [], else: Enum.to_list(s..(s + c - 1))

      [_, start] ->
        [String.to_integer(start)]
    end)
  end

  def find_enclosing_describe(lines, line_num) do
    line_num..1//-1
    |> Enum.find(fn num ->
      line = Enum.at(lines, num - 1, "")
      String.match?(line, ~r/^\s*describe\s+["(]/)
    end)
  end

  # Walk backwards but stop at describe boundary to avoid crossing into another block
  def find_enclosing_test(lines, line_num) do
    line_num..1//-1
    |> Enum.reduce_while(nil, fn num, _acc ->
      line = Enum.at(lines, num - 1, "")

      cond do
        String.match?(line, ~r/^\s*test\s+["(]/) -> {:halt, num}
        String.match?(line, ~r/^\s*describe\s+["(]/) -> {:halt, nil}
        true -> {:cont, nil}
      end
    end)
  end

  defp run_tests(targets, test_opts) do
    extra = extra_args(test_opts)
    args = ["test" | targets] ++ extra

    extra_str = Enum.join(extra, " ")

    IO.puts([
      IO.ANSI.format([
        :cyan,
        "\nTest command: mix test [#{length(targets)} tests] #{extra_str}\n"
      ])
    ])

    port = CheckEscript.Port.open("mix", args)
    status = CheckEscript.Runner.stream_port_output(port)
    {status, ""}
  end

  defp extra_args(opts) do
    test_args = if opts[:test_args], do: String.split(opts[:test_args]), else: []
    repeat = if opts[:repeat], do: ["--repeat-until-failure", to_string(opts[:repeat])], else: []
    test_args ++ repeat
  end
end
