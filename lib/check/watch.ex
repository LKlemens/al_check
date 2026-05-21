defmodule CheckEscript.Watch do
  @moduledoc "Real-time monitoring of test partition files."

  def run do
    partition_files = Path.wildcard(".check/test_partition_*.txt")

    if Enum.empty?(partition_files) do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "No test partition files found in .check/ directory.\n",
          "Run tests first with: check --only test"
        ]),
        IO.ANSI.reset()
      ])

      System.halt(1)
    end

    IO.puts([
      IO.ANSI.format([:green, "Watching #{length(partition_files)} test partition file(s)..."]),
      IO.ANSI.reset(),
      "\n"
    ])

    port =
      Port.open({:spawn_executable, System.find_executable("tail")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-f", "-q", "-n", "+1" | partition_files]
      ])

    stream_port_output(port)
  end

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
