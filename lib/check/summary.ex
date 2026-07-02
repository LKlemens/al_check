defmodule Check.Summary do
  @moduledoc "Results summary, failure details, and output persistence."

  alias Check.{Coverage, Failed, Tasks, UI}

  def print(results, total_seconds, tasks, coverage, output_mode \\ :status) do
    IO.write("\n")

    save_credo_outputs(results)
    save_format_failure_marker(results)
    merge_partition_outputs(results)

    partition_failures =
      if Tasks.has_test_tasks?(tasks), do: Failed.extract(), else: []

    check_failures =
      results
      |> Enum.filter(fn {_name, status, _output} -> status != 0 end)
      |> Enum.flat_map(fn {_name, _status, output} -> Failed.extract_from_output(output) end)

    Failed.save((partition_failures ++ check_failures) |> Enum.uniq())

    # Skip coverage when tests failed: the numbers would be incomplete and
    # misleading. A threshold-only failure (tests passed) still reports.
    tests_failed? =
      Enum.any?(results, fn {name, status, _output} ->
        String.starts_with?(name, "Tests (") and status != 0
      end)

    coverage_failed? =
      if Tasks.has_test_tasks?(tasks) and coverage.mod != false and not tests_failed? do
        result = Coverage.merge(coverage)
        Coverage.show_modified_files_coverage()
        result == :failed
      else
        false
      end

    failed_checks = Enum.filter(results, fn {_name, status, _output} -> status != 0 end)

    IO.puts("\nCompleted in #{total_seconds}s")
    report_result(failed_checks, coverage_failed?, results, tests_failed?, output_mode)
  end

  # `{:sections, policy}` prints each section's full output as a contiguous block:
  # `:always` for every section, `:on_failure` for failed ones only. No-op for
  # `:status` / `:verbose`.
  defp print_sections_output(results, {:sections, policy}) do
    sections =
      if policy == :always,
        do: results,
        else: Enum.filter(results, fn {_name, status, _output} -> status != 0 end)

    Enum.each(sections, &print_section_block/1)
  end

  defp print_sections_output(_results, _output_mode), do: :ok

  defp print_section_block({name, status, output}) do
    {icon, color, label} = UI.format_task_status(status, {0, 0})
    IO.puts([IO.ANSI.format([color, :bright, "\n#{icon} #{name} #{label}"])])
    IO.puts(String.duplicate("-", 40))
    print_check_output(output)
  end

  # Parallel test failures are almost always caused by missing per-partition config
  # (shared DB / shared port), so nudge only when a multi-partition run fails.
  defp maybe_warn_parallel_partitions(results, true) do
    partition_count =
      Enum.count(results, fn {name, _status, _output} -> String.starts_with?(name, "Tests (") end)

    if partition_count > 1 do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "\nPlease be aware that running tests in parallel requires " <>
            "a tweak to your configuration (separate DB + HTTP port per partition) - without it they fail.\n" <>
            "See https://al-check.hexdocs.pm/0.1.28/test-partitioning.html"
        ])
      ])
    end
  end

  defp maybe_warn_parallel_partitions(_results, false), do: :ok

  defp report_result([], false, results, _tests_failed?, output_mode) do
    print_sections_output(results, output_mode)
    IO.puts([IO.ANSI.format([:green, "\n✓ All checks passed!"])])
  end

  defp report_result([], true, results, _tests_failed?, output_mode) do
    print_sections_output(results, output_mode)
    System.halt(1)
  end

  defp report_result(failed_checks, _coverage_failed?, results, tests_failed?, output_mode) do
    IO.puts([IO.ANSI.format([:red, "\n✗ #{length(failed_checks)} check(s) failed"])])

    # In sections mode the full per-section blocks are printed instead of the
    # compact failure details.
    case output_mode do
      {:sections, _policy} -> print_sections_output(results, output_mode)
      _ -> print_failure_details(failed_checks)
    end

    maybe_warn_parallel_partitions(results, tests_failed?)
    System.halt(1)
  end

  defp print_failure_details(failed_checks) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("FAILURE DETAILS")
    IO.puts(String.duplicate("=", 60))

    Enum.each(failed_checks, &print_check_failure/1)
  end

  defp print_check_failure({name, status, output}) do
    IO.puts([IO.ANSI.format([:red, :bright, "\n#{name} failed:"])])
    IO.puts(String.duplicate("-", 40))

    if String.starts_with?(name, "Tests (") do
      print_test_failure(status, output)
    else
      print_check_output(output)
    end
  end

  defp print_test_failure(status, output) do
    IO.puts(extract_test_summary(output))

    if status == :warnings do
      warning_count = output |> String.split("warning:") |> length() |> Kernel.-(1)
      IO.puts([IO.ANSI.format([:yellow, "#{warning_count} warning(s) detected"])])
    end

    IO.puts([IO.ANSI.format([:yellow, "\nFull test output saved to .check/check_tests.txt"])])

    IO.puts([
      IO.ANSI.format([
        :cyan,
        "To view error logs: check --watch (live), or re-run with " <>
          "check --only test --verbose-sections (grouped) / --verbose (streamed), " <>
          "or rerun failed tests with check --failed"
      ])
    ])
  end

  defp print_check_output(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&IO.puts(colorize_line(&1)))
  end

  def colorize_line(line) do
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
  end

  def extract_test_summary(output) when is_binary(output) do
    # Take the real column-0 summary line (the last one), skipping indented
    # "N tests, M failures" fragments printed inside failure blocks.
    case Regex.scan(~r/^\d[^\n]*\d+ failures?[^\n]*/m, output) do
      [] -> "See .check/check_tests.txt for details"
      matches -> matches |> List.last() |> List.first()
    end
  end

  defp save_credo_outputs(results) do
    File.mkdir_p!(".check")

    Enum.each(results, fn
      {"Credo", _status, output} -> File.write!(".check/credo.txt", output)
      {"Credo Strict", _status, output} -> File.write!(".check/credo_strict.txt", output)
      _ -> :ok
    end)
  end

  defp save_format_failure_marker(results) do
    File.mkdir_p!(".check")

    format_failed? =
      Enum.any?(results, fn {name, status, _output} ->
        name == "Formatting" and status != 0
      end)

    if format_failed?,
      do: File.write!(".check/.format_failed", ""),
      else: File.rm(".check/.format_failed")
  end

  defp merge_partition_outputs(results) do
    partition_results =
      results
      |> Enum.filter(fn {name, _status, _output} -> String.starts_with?(name, "Tests (") end)
      |> Enum.sort_by(&partition_number/1)

    if Enum.any?(partition_results) do
      timestamp = DateTime.utc_now() |> DateTime.to_string()

      content =
        ["Test Output - Generated at #{timestamp}", String.duplicate("=", 60), ""] ++
          Enum.flat_map(partition_results, fn {name, _status, output} ->
            ["\nPARTITION #{partition_label(name)}", String.duplicate("-", 60), output, ""]
          end)

      File.mkdir_p!(".check")
      File.write!(".check/check_tests.txt", Enum.join(content, "\n"))
    end
  end

  defp partition_number({name, _status, _output}) do
    case Regex.run(~r/Tests \((\d+)\/\d+\)/, name) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp partition_label(name) do
    case Regex.run(~r/Tests \((\d+)\/(\d+)\)/, name) do
      [_, p, t] -> "#{p}/#{t}"
      _ -> "?"
    end
  end
end
