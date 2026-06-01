defmodule Check.Fix do
  @moduledoc "Auto-fix mode — runs configurable fix commands."

  @default_fix [
    %{"run" => "mix format"},
    %{"run" => "mix recode", "files" => ".check/credo*.txt"}
  ]

  def run do
    IO.puts("Applying fixes...\n")

    commands = load_fix_commands()
    Enum.each(commands, &run_command/1)

    IO.puts([IO.ANSI.format([:green, "✓ All fixes applied successfully"])])
  end

  defp run_command(%{"run" => cmd, "files" => source}) do
    files = load_files(source)

    if Enum.empty?(files) do
      IO.puts([IO.ANSI.format([:yellow, "No files found from #{source}, skipping: #{cmd}\n"])])
    else
      IO.puts([IO.ANSI.format([:cyan, "Running: #{cmd} (#{length(files)} file(s))"])])
      Enum.each(files, fn f -> IO.puts("  - #{f}") end)

      [base | args] = String.split(cmd)
      execute(base, args ++ files, cmd)
    end
  end

  defp run_command(%{"run" => cmd}) do
    IO.puts([IO.ANSI.format([:cyan, "Running: #{cmd}"])])
    execute("sh", ["-c", cmd], cmd)
  end

  defp execute(bin, args, label) do
    {output, status} = System.cmd(bin, args, stderr_to_stdout: true)

    if status == 0 do
      if output != "", do: IO.puts(output)
      IO.puts([IO.ANSI.format([:green, "✓ #{label}\n"])])
    else
      IO.puts(output)
      IO.puts([IO.ANSI.format([:red, "✗ #{label} failed"])])
      System.halt(1)
    end
  end

  defp load_files(source) do
    Path.wildcard(source)
    |> Enum.flat_map(fn path -> path |> File.read!() |> extract_file_paths() end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_file_paths(output) do
    ~r/^\s*┃?\s+([^\s:]+\.exs?):\d+/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, file] -> file end)
  end

  defp load_fix_commands do
    case Check.Config.load() do
      {:ok, config} when is_map_key(config, "fix") -> config["fix"]
      _ -> @default_fix
    end
  end
end
