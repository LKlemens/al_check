defmodule CheckEscript.Fix do
  @moduledoc "Auto-fix mode for format and credo issues."

  def run do
    IO.puts("Checking for failures to fix...\n")

    check_and_fix_format()

    IO.puts("\nReading stored credo outputs from check/...\n")

    files =
      [".check/credo.txt", ".check/credo_strict.txt"]
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(fn file ->
        content = File.read!(file)
        extract_files_from_credo_output(content)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.empty?(files) do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "No credo errors found. Maybe rerun 'check --only credo'."
        ]),
        IO.ANSI.reset()
      ])
    else
      IO.puts("Found #{length(files)} file(s) with issues:\n")
      Enum.each(files, fn file -> IO.puts("  - #{file}") end)

      IO.puts([
        "\n",
        IO.ANSI.format([:yellow, "Running mix recode on #{length(files)} file(s)..."]),
        IO.ANSI.reset(),
        "\n"
      ])

      {output, status} = System.cmd("mix", ["recode" | files], stderr_to_stdout: true)
      IO.puts(output)

      if status == 0 do
        IO.puts([
          IO.ANSI.format([:green, "\n✓ Auto-fixes applied successfully"]),
          IO.ANSI.reset()
        ])
      else
        IO.puts([IO.ANSI.format([:red, "\n✗ Recode exited with errors"]), IO.ANSI.reset()])
        System.halt(1)
      end
    end
  end

  defp check_and_fix_format do
    if File.exists?(".check/.format_failed") do
      IO.puts([IO.ANSI.format([:red, "✗ Format check failed previously"])])
      IO.puts([IO.ANSI.format([:yellow, "Running mix format to fix..."])])

      {output, status} = System.cmd("mix", ["format"], stderr_to_stdout: true)

      if status == 0 do
        File.rm(".check/.format_failed")
        IO.puts([IO.ANSI.format([:green, "✓ Format fixed successfully"])])
      else
        IO.puts(output)
        IO.puts([IO.ANSI.format([:red, "✗ Format fix failed"])])
        System.halt(1)
      end
    else
      IO.puts([IO.ANSI.format([:green, "✓ Format check passed"])])
    end
  end

  def extract_files_from_credo_output(output) do
    ~r/^\s*┃?\s+([^\s:]+\.exs?):\d+/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, file] -> file end)
  end
end
