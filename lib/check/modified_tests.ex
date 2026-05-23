defmodule CheckEscript.ModifiedTests do
  @moduledoc """
  Detects modified tests on the current branch vs master.

  - If setup/setup_all/describe changed → runs the whole file
  - Otherwise → runs only the specific modified test lines
  """

  def run do
    modified_files = get_modified_test_files()

    if Enum.empty?(modified_files) do
      IO.puts("No modified test files on this branch")
      0
    else
      test_targets = Enum.flat_map(modified_files, &targets_for_file/1)
      run_tests(test_targets)
    end
  end

  defp get_modified_test_files do
    case System.cmd("git", ["diff", "--name-only", "--diff-filter=d", "master...", "--", "test/**/*_test.exs"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> Enum.filter(&File.exists?/1)

      {error, _} ->
        IO.puts([IO.ANSI.format([:red, "git diff failed: #{String.trim(error)}"])])
        []
    end
  end

  defp targets_for_file(file) do
    changed_lines = get_changed_lines(file)

    if Enum.empty?(changed_lines) do
      []
    else
      if setup_or_describe_changed?(file, changed_lines) do
        IO.puts([IO.ANSI.format([:yellow, "  #{file} (setup/describe changed, running whole file)"])])
        [file]
      else
        find_test_lines(file, changed_lines)
      end
    end
  end

  defp get_changed_lines(file) do
    {output, _status} = System.cmd("git", ["diff", "-U0", "master...", "--", file], stderr_to_stdout: true)

    # Parse @@ hunk headers: @@ -old,count +new,count @@
    ~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
    |> Regex.scan(output)
    |> Enum.flat_map(fn
      [_, start, ""] -> [String.to_integer(start)]
      [_, start, count] ->
        s = String.to_integer(start)
        c = String.to_integer(count)
        if c == 0, do: [], else: Enum.to_list(s..(s + c - 1))
      [_, start] -> [String.to_integer(start)]
    end)
  end

  defp setup_or_describe_changed?(file, changed_lines) do
    lines = File.read!(file) |> String.split("\n")

    Enum.any?(changed_lines, fn line_num ->
      line = Enum.at(lines, line_num - 1, "")
      String.match?(line, ~r/^\s*(setup|setup_all|describe)\b/)
    end)
  end

  defp find_test_lines(file, changed_lines) do
    lines = File.read!(file) |> String.split("\n")

    # For each changed line, walk up to find the nearest `test "` definition
    test_line_numbers =
      changed_lines
      |> Enum.map(fn line_num -> find_enclosing_test(lines, line_num) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if Enum.empty?(test_line_numbers) do
      # changed lines are outside any test block (e.g. module-level code)
      IO.puts([IO.ANSI.format([:yellow, "  #{file} (module-level change, running whole file)"])])
      [file]
    else
      targets = Enum.map(test_line_numbers, fn line -> "#{file}:#{line}" end)
      Enum.each(targets, fn t -> IO.puts([IO.ANSI.format([:cyan, "  #{t}"])]) end)
      targets
    end
  end

  # Walk backwards from changed_line to find the nearest `test "` or `test(`
  defp find_enclosing_test(lines, line_num) do
    line_num..1//-1
    |> Enum.find(fn num ->
      line = Enum.at(lines, num - 1, "")
      String.match?(line, ~r/^\s*test\s+["(]/)
    end)
  end

  defp run_tests(targets) do
    IO.puts([IO.ANSI.format([:cyan, "\nRunning #{length(targets)} test target(s)...\n"])])

    port =
      CheckEscript.Port.open("mix", ["test" | targets])

    CheckEscript.Runner.stream_port_output(port)
  end
end
