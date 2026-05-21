defmodule CheckEscript.Summary do
  @moduledoc "Results summary, failure details, and output persistence."

  alias CheckEscript.{Coverage, Failed, Tasks}

  def print(results, total_seconds, tasks, coverage) do
    IO.write("\n")

    save_credo_outputs(results)
    save_format_failure_marker(results)
    merge_partition_outputs(results)

    # extract failed tests from partition outputs and all failed check outputs
    partition_failures =
      if Tasks.has_test_tasks?(tasks), do: Failed.extract(), else: []

    check_failures =
      results
      |> Enum.filter(fn {_name, status, _output} -> status != 0 end)
      |> Enum.flat_map(fn {_name, _status, output} ->
        Failed.extract_from_output(output)
      end)

    Failed.save((partition_failures ++ check_failures) |> Enum.uniq())

    coverage_failed? =
      if Tasks.has_test_tasks?(tasks), do: Coverage.merge(coverage) == :failed, else: false

    failed_checks = Enum.filter(results, fn {_name, status, _output} -> status != 0 end)

    IO.puts("\nCompleted in #{total_seconds}s")

    cond do
      Enum.empty?(failed_checks) and not coverage_failed? ->
        IO.puts([IO.ANSI.format([:green, "\n✓ All checks passed!"])])

      Enum.empty?(failed_checks) and coverage_failed? ->
        System.halt(1)

      true ->
        IO.puts([IO.ANSI.format([:red, "\n✗ #{length(failed_checks)} check(s) failed"])])
        print_failure_details(failed_checks)
        System.halt(1)
    end
  end

  defp save_credo_outputs(results) do
    File.mkdir_p!(".check")

    results
    |> Enum.filter(fn {name, _status, _output} ->
      name in ["Credo", "Credo Strict"]
    end)
    |> Enum.each(fn {name, _status, output} ->
      filename =
        case name do
          "Credo" -> ".check/credo.txt"
          "Credo Strict" -> ".check/credo_strict.txt"
        end

      File.write!(filename, output)
    end)
  end

  defp save_format_failure_marker(results) do
    File.mkdir_p!(".check")

    format_failed? =
      Enum.any?(results, fn {name, status, _output} ->
        name == "Formatting" and status != 0
      end)

    if format_failed? do
      File.write!(".check/.format_failed", "")
    else
      File.rm(".check/.format_failed")
    end
  end

  defp print_failure_details(failed_checks) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("FAILURE DETAILS")
    IO.puts(String.duplicate("=", 60))

    Enum.each(failed_checks, fn {name, status, output} ->
      IO.puts([IO.ANSI.format([:red, :bright, "\n#{name} failed:"])])
      IO.puts(String.duplicate("-", 40))

      if String.starts_with?(name, "Tests (") do
        summary = extract_test_summary(output)
        IO.puts(summary)

        if status == :warnings do
          warning_count = output |> String.split("warning:") |> length() |> Kernel.-(1)
          IO.puts([IO.ANSI.format([:yellow, "#{warning_count} warning(s) detected"])])
        end

        IO.puts([IO.ANSI.format([:yellow, "\nFull test output saved to check_tests.txt"])])
      else
        lines =
          output
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))

        Enum.each(lines, fn line ->
          formatted_line =
            cond do
              String.contains?(line, "** ") ->
                [IO.ANSI.format([:red, line])]

              String.contains?(line, "warning:") ->
                [IO.ANSI.format([:yellow, line])]

              String.contains?(line, "error:") ->
                [IO.ANSI.format([:red, line])]

              String.contains?(line, "┃") or String.contains?(line, "│") ->
                [IO.ANSI.format([:cyan, line])]

              true ->
                line
            end

          IO.puts(formatted_line)
        end)
      end
    end)
  end

  defp extract_test_summary(output) when is_binary(output) do
    case Regex.run(~r/(\d+ tests?, \d+ failures?(, \d+ excluded)?.*)/m, output) do
      [_, summary | _] -> summary
      nil -> "See .check/check_tests.txt for details"
    end
  end

  defp extract_test_summary(_output) do
    "See .check/check_tests.txt for details"
  end

  defp merge_partition_outputs(results) do
    partition_results =
      results
      |> Enum.filter(fn {name, _status, _output} ->
        String.starts_with?(name, "Tests (")
      end)
      |> Enum.sort_by(fn {name, _status, _output} ->
        case Regex.run(~r/Tests \((\d+)\/\d+\)/, name) do
          [_, partition_str] -> String.to_integer(partition_str)
          _ -> 0
        end
      end)

    if Enum.any?(partition_results) do
      timestamp = DateTime.utc_now() |> DateTime.to_string()

      content =
        [
          "Test Output - Generated at #{timestamp}",
          String.duplicate("=", 60),
          ""
        ] ++
          Enum.flat_map(partition_results, fn {name, _status, output} ->
            partition_num =
              case Regex.run(~r/Tests \((\d+)\/(\d+)\)/, name) do
                [_, p, t] -> "#{p}/#{t}"
                _ -> "?"
              end

            [
              "\nPARTITION #{partition_num}",
              String.duplicate("-", 60),
              output,
              ""
            ]
          end)

      File.mkdir_p!(".check")
      File.write!(".check/check_tests.txt", Enum.join(content, "\n"))
    end
  end
end
