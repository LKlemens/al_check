defmodule CheckEscript.Failed do
  @moduledoc "Failed test extraction and re-running."

  def run(repeat) do
    failed_tests = load_failed_tests()

    if Enum.empty?(failed_tests) do
      IO.puts([IO.ANSI.format([:green, "No failed tests to run!"]), IO.ANSI.reset()])
    else
      IO.puts("Running #{length(failed_tests)} failed test(s)...\n")
      run_tests(failed_tests, repeat)
    end
  end

  def extract do
    if File.exists?(".check/check_tests.txt") do
      ".check/check_tests.txt" |> File.read!() |> extract_from_output()
    else
      []
    end
  end

  def extract_from_output(output) do
    failures =
      ~r/\d+\)\s+test\s+.*?\n\s+(test\/[^\s:]+\.exs):(\d+)/m
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
    String.contains?(output, "Expected minimum coverage") and
      Regex.match?(~r/\d+ tests?, 0 failures/, output)
  end

  # -- Private --

  defp load_failed_tests do
    file = ".check/failed_tests.txt"

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

  defp run_tests(failed_tests, repeat) do
    test_args = read_saved_test_args()
    repeat_args = if repeat, do: ["--repeat-until-failure", to_string(repeat)], else: []
    all_args = ["test"] ++ test_args ++ repeat_args ++ ["failed_tests"]

    IO.puts([IO.ANSI.format([:cyan, "Test command: mix #{Enum.join(all_args, " ")}\n"])])

    port = CheckEscript.Port.open("mix", all_args ++ failed_tests)

    status = CheckEscript.Runner.stream_port_output(port)

    if status == 0 do
      IO.puts([IO.ANSI.format([:green, "\n✓ All previously failed tests now pass!"]), IO.ANSI.reset()])
    else
      IO.puts([IO.ANSI.format([:red, "\n✗ Some tests still failing"]), IO.ANSI.reset()])
      System.halt(1)
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
