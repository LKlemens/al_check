defmodule Check.Failed do
  @moduledoc "Failed test extraction and re-running."

  @failed_file ".check/failed_tests.txt"
  @still_failing_file ".check/still_failing.txt"

  def run(opts, coverage \\ %{mod: false}) when is_list(opts) do
    source = if opts[:all_failed], do: @failed_file, else: preferred_source()
    failed_tests = load_failed_tests(source)

    if Enum.empty?(failed_tests) do
      IO.puts([IO.ANSI.format([:green, "No failed tests to run!"]), IO.ANSI.reset()])
    else
      IO.puts("Running #{length(failed_tests)} failed test(s)...\n")
      # The full original failed list runs on `--all-failed` and on the first `--failed`
      # (before any `still_failing.txt` exists); only then is coverage data complete.
      full_list? = source == @failed_file
      run_tests(failed_tests, opts[:repeat], coverage, full_list?)
    end
  end

  defp preferred_source do
    if File.exists?(@still_failing_file), do: @still_failing_file, else: @failed_file
  end

  def extract do
    if File.exists?(".check/check_tests.txt") do
      ".check/check_tests.txt" |> File.read!() |> extract_from_output()
    else
      []
    end
  end

  def extract_from_output(output) do
    # Match all failure types: test, doctest, property, etc.
    # Pattern: N) <anything>\n     test/path/file.exs:line
    failures =
      ~r/\d+\)\s+.*?\n\s+(test\/[^\s:]+\.exs):(\d+)/m
      |> Regex.scan(output)
      |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)

    warnings =
      ~r/└─ (test\/[^\s:]+\.exs):(\d+)/m
      |> Regex.scan(output)
      |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)

    failures ++ warnings
  end

  def save(failed_tests) do
    if Enum.any?(failed_tests) do
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", Enum.join(failed_tests, "\n"))
      IO.puts([IO.ANSI.format([:yellow, "\nFailed tests saved to .check/failed_tests.txt"])])
    end
  end

  def save_test_args(test_args) do
    File.mkdir_p!(".check")
    File.write!(".check/test_args.txt", test_args || "--warnings-as-errors")
  end

  def detect_warnings_in_output(output) do
    String.contains?(output, "warning:")
  end

  def coverage_threshold_failure?(output) do
    (String.contains?(output, "Expected minimum coverage") or
       String.contains?(output, "Coverage test failed, threshold not met")) and
      Regex.match?(~r/\d+ tests?, 0 failures/, output)
  end

  # -- Private --

  defp load_failed_tests(file) do
    if File.exists?(file) do
      file |> File.read!() |> String.split("\n", trim: true)
    else
      IO.puts([
        IO.ANSI.format([:red, "No failed tests found. Run 'check --only test' first."]),
        IO.ANSI.reset()
      ])

      System.halt(1)
    end
  end

  defp run_tests(failed_tests, repeat, coverage, full_list?) do
    test_args = read_saved_test_args()
    repeat_args = if repeat, do: ["--repeat-until-failure", to_string(repeat)], else: []
    all_args = ["test"] ++ test_args ++ repeat_args ++ ["failed_tests"]

    IO.puts([IO.ANSI.format([:cyan, "Test command: mix #{Enum.join(all_args, " ")}\n"])])

    port = Check.Port.open("mix", all_args ++ failed_tests)

    {status, output} = stream_and_capture(port)

    if status == 0 do
      File.rm(@still_failing_file)

      IO.puts([
        IO.ANSI.format([:green, "\n✓ All previously failed tests now pass!"]),
        IO.ANSI.reset()
      ])

      maybe_show_coverage(coverage, full_list?)
    else
      still_failing = extract_from_output(output)
      update_still_failing(failed_tests, still_failing)

      IO.puts([IO.ANSI.format([:red, "\n✗ Some tests still failing"]), IO.ANSI.reset()])
      System.halt(1)
    end
  end

  # When coverage is configured, surface it after a passing run. Only the full original
  # failed list yields complete data; a `--failed` subset rerun overwrites
  # `cover/failed.coverdata` with partial data, so we point the user at `--all-failed`.
  defp maybe_show_coverage(%{mod: mod} = coverage, full_list?) when mod != false do
    if full_list? do
      Check.Coverage.merge(coverage)
      Check.Coverage.show_modified_files_coverage()
    else
      IO.puts([
        IO.ANSI.format([
          :cyan,
          "\nℹ Coverage skipped: only the still-failing subset was re-run, so coverage " <>
            "data is incomplete. Run `check --all-failed` to re-run the full failed set " <>
            "and see a coverage report."
        ])
      ])
    end
  end

  defp maybe_show_coverage(_coverage, _full_list?), do: :ok

  # Stream output to stdout and capture it for failure extraction
  defp stream_and_capture(port) do
    spinner = Check.Spinner.start()
    {output, status} = do_stream_and_capture(port, "")
    Check.Spinner.stop(spinner)
    {status, output}
  end

  defp do_stream_and_capture(port, acc) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        do_stream_and_capture(port, acc <> data)

      {^port, {:exit_status, status}} ->
        {acc, status}
    end
  end

  defp update_still_failing(original, still_failing) do
    if Enum.empty?(still_failing) do
      File.rm(@still_failing_file)
    else
      passed = length(original) - length(still_failing)

      if passed > 0 do
        IO.puts([
          IO.ANSI.format([:yellow, "#{passed} test(s) now pass, removed from still-failing list"])
        ])
      end

      File.mkdir_p!(".check")
      File.write!(@still_failing_file, Enum.join(still_failing, "\n"))
      IO.puts([IO.ANSI.format([:yellow, "Still failing saved to #{@still_failing_file}"])])
    end
  end

  defp read_saved_test_args do
    case File.read(".check/test_args.txt") do
      {:ok, content} -> content |> String.trim() |> String.split() |> fix_cover_flags()
      {:error, _} -> ["--warnings-as-errors"]
    end
  end

  # --export-coverage dumps coverage to cover/ instead of printing per-file results immediately,
  # so we can sum up coverage as a last step via mix test.coverage
  defp fix_cover_flags([]), do: []

  defp fix_cover_flags(["--cover" | rest]),
    do: ["--cover", "--export-coverage", "failed" | fix_cover_flags(rest)]

  defp fix_cover_flags([arg | rest]), do: [arg | fix_cover_flags(rest)]
end
