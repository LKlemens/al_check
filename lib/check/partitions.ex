defmodule Check.Partitions do
  @moduledoc "Run commands across all test partitions."

  def run_for_all(cmd, partitions) do
    IO.puts("Running across #{partitions} partition(s):\n")

    results =
      Enum.map(1..partitions, fn partition ->
        full_cmd = "MIX_ENV=test MIX_TEST_PARTITION=#{partition} #{cmd}"
        IO.puts([IO.ANSI.format([:cyan, "  $ #{full_cmd}"])])

        spinner = Check.Spinner.start("Partition #{partition}/#{partitions}")
        {output, status} = System.cmd("sh", ["-c", full_cmd], stderr_to_stdout: true)
        Check.Spinner.stop(spinner)

        if status == 0 do
          IO.puts([IO.ANSI.format([:green, "  ✓ Partition #{partition}/#{partitions}\n"])])
        else
          IO.puts(output)
          IO.puts([IO.ANSI.format([:red, "  ✗ Partition #{partition}/#{partitions}\n"])])
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
