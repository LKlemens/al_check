defmodule Check.Partitions do
  @moduledoc "Run commands across all test partitions."

  def run_for_all(cmd, partitions) do
    IO.puts("Running across #{partitions} partition(s) in parallel:\n")

    Enum.each(1..partitions, fn partition ->
      IO.puts([
        IO.ANSI.format([:cyan, "  $ MIX_ENV=test MIX_TEST_PARTITION=#{partition} #{cmd}"])
      ])
    end)

    IO.puts("")
    spinner = Check.Spinner.start("Running #{partitions} partition(s)")

    results =
      1..partitions
      |> Task.async_stream(
        fn partition ->
          full_cmd = "MIX_ENV=test MIX_TEST_PARTITION=#{partition} #{cmd}"
          {output, status} = System.cmd("sh", ["-c", full_cmd], stderr_to_stdout: true)
          {partition, status, output}
        end,
        timeout: :infinity,
        max_concurrency: partitions
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Check.Spinner.stop(spinner)

    results =
      Enum.map(results, fn {partition, status, output} ->
        if status == 0 do
          IO.puts([IO.ANSI.format([:green, "  ✓ Partition #{partition}/#{partitions}"])])
        else
          IO.puts(output)
          IO.puts([IO.ANSI.format([:red, "  ✗ Partition #{partition}/#{partitions}"])])
        end

        {partition, status}
      end)

    failed = Enum.filter(results, fn {_, status} -> status != 0 end)

    if Enum.empty?(failed) do
      IO.puts([IO.ANSI.format([:green, "✓ All #{partitions} partition(s) done"])])
    else
      IO.puts([IO.ANSI.format([:red, "✗ #{length(failed)} partition(s) failed"])])
      System.halt(1)
    end
  end
end
