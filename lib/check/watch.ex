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

    port = CheckEscript.Port.open("tail", ["-f", "-q", "-n", "+1" | partition_files])
    CheckEscript.Runner.stream_port_output(port)
  end
end
