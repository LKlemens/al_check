defmodule Mix.Tasks.Check.Build do
  use Mix.Task

  @shortdoc "Builds the check escript to scripts/check"

  @moduledoc """
  Builds the check escript without installing it globally.

  ## Usage

      mix check.build

  The escript will be available at `scripts/check`.
  """

  @spec run([String.t()]) :: :ok
  def run(_args) do
    check_path = get_check_path()
    spinner = Check.Spinner.start("Building escript in #{check_path}")

    case build_escript(check_path) do
      :ok ->
        Check.Spinner.stop(spinner)
        escript_path = Path.join(check_path, "scripts/check")
        Mix.shell().info([IO.ANSI.format([:green, "✓ Built: #{escript_path}\n"])])
        Mix.shell().info("  Run directly:")
        Mix.shell().info("    #{escript_path}\n")
        Mix.shell().info("  Or add an alias to your shell config:")
        Mix.shell().info("    alias check='#{Path.expand(escript_path)}'\n")

      {:error, reason} ->
        Check.Spinner.stop(spinner)
        Mix.raise("Failed to build escript: #{reason}")
    end
  end

  defp get_check_path do
    case Mix.Project.deps_paths()[:al_check] do
      nil -> File.cwd!()
      path -> path
    end
  end

  defp build_escript(path) do
    with {_, 0} <- System.cmd("mix", ["deps.get"], cd: path, stderr_to_stdout: true),
         {_, 0} <- System.cmd("mix", ["escript.build"], cd: path, stderr_to_stdout: true) do
      :ok
    else
      {output, _status} -> {:error, output}
    end
  end
end
