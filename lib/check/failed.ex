defmodule CheckEscript.Failed do
  @moduledoc "Failed test extraction and re-running."

  def run(repeat) do
    failed_tests_file = ".check/failed_tests.txt"

    unless File.exists?(failed_tests_file) do
      IO.puts([
        IO.ANSI.format([:red, "No failed tests found. Run 'check --only test' first."]),
        IO.ANSI.reset()
      ])

      System.halt(1)
    end

    failed_tests =
      failed_tests_file
      |> File.read!()
      |> String.split("\n", trim: true)

    if Enum.empty?(failed_tests) do
      IO.puts([
        IO.ANSI.format([:green, "No failed tests to run!"]),
        IO.ANSI.reset()
      ])
    else
      IO.puts("Running #{length(failed_tests)} failed test(s)...\n")

      test_args = read_saved_test_args()
      repeat_args = if repeat, do: ["--repeat-until-failure", to_string(repeat)], else: []
      all_args = ["test"] ++ test_args ++ repeat_args ++ ["failed_tests"]
      test_cmd = "mix " <> Enum.join(all_args, " ")
      IO.puts([IO.ANSI.format([:cyan, "Test command: #{test_cmd}\n"])])

      port =
        Port.open({:spawn_executable, System.find_executable("mix")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: all_args ++ failed_tests
        ])

      status = stream_port_output(port)

      if status == 0 do
        IO.puts([
          IO.ANSI.format([:green, "\n✓ All previously failed tests now pass!"]),
          IO.ANSI.reset()
        ])
      else
        IO.puts([
          IO.ANSI.format([:red, "\n✗ Some tests still failing"]),
          IO.ANSI.reset()
        ])

        System.halt(1)
      end
    end
  end

  def extract do
    if File.exists?(".check/check_tests.txt") do
      content = File.read!(".check/check_tests.txt")
      extract_from_output(content)
    else
      []
    end
  end

  def extract_from_output(output) do
    failures =
      ~r/\d+\)\s+test\s+.*?\n\s+(test\/[^\s:]+\.exs):(\d+)/m
      |> Regex.scan(output)
      |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)

    warnings = extract_warning_locations(output)
    failures ++ warnings
  end

  def extract_warning_locations(content) do
    ~r/└─ (test\/[^\s:]+\.exs):(\d+)/m
    |> Regex.scan(content)
    |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)
  end

  def save(failed_tests) do
    if Enum.any?(failed_tests) do
      File.mkdir_p!(".check")
      content = Enum.join(failed_tests, "\n")
      File.write!(".check/failed_tests.txt", content)
      IO.puts([IO.ANSI.format([:yellow, "\nFailed tests saved to .check/failed_tests.txt"])])
    end
  end

  def save_test_args(test_args) do
    File.mkdir_p!(".check")
    test_flags = test_args || "--warnings-as-errors"
    File.write!(".check/test_args.txt", test_flags)
  end

  def read_saved_test_args do
    case File.read(".check/test_args.txt") do
      {:ok, content} -> content |> String.trim() |> String.split() |> fix_cover_flags()
      {:error, _} -> ["--warnings-as-errors"]
    end
  end

  def coverage_threshold_failure?(output) do
    String.contains?(output, "Expected minimum coverage") and
      Regex.match?(~r/\d+ tests?, 0 failures/, output)
  end

  def detect_warnings_in_output(output) do
    String.contains?(output, "warning:")
  end

  # --export-coverage dumps coverage to cover/ instead of printing per-file results immediately,
  # so we can sum up coverage as a last step via mix test.coverage
  defp fix_cover_flags([]), do: []

  defp fix_cover_flags(["--cover" | rest]),
    do: ["--cover", "--export-coverage", "failed" | fix_cover_flags(rest)]

  defp fix_cover_flags([arg | rest]), do: [arg | fix_cover_flags(rest)]

  defp stream_port_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        stream_port_output(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end
end
