defmodule Mix.Tasks.Check.Install do
  use Mix.Task

  @shortdoc "Builds and installs the check escript globally"

  @moduledoc """
  Builds and installs the al_check escript to ~/.mix/escripts/

  ## Usage

      mix check.install

  The escript will be available globally as the `check` command.

  ## Installation Location

  The escript is installed to:
  - macOS/Linux: `~/.mix/escripts/check`
  - Windows: `%USERPROFILE%/.mix/escripts/check`

  Make sure `~/.mix/escripts` is in your PATH.

  ## Example

      # Install the escript
      mix check.install

      # Then use from anywhere
      check
      check --fast
      check --only test
  """

  @spec run([String.t()]) :: :ok
  def run(_args) do
    # Get the al_check dependency path or current directory
    check_path = get_check_path()

    spinner = CheckEscript.Spinner.start("Building escript in #{check_path}")

    case build_escript(check_path) do
      :ok ->
        CheckEscript.Spinner.stop(spinner)
        spinner2 = CheckEscript.Spinner.start("Installing escript globally")

        case install_escript(check_path) do
          :ok ->
            CheckEscript.Spinner.stop(spinner2)
            Mix.shell().info("""

            \e[35m        @@          \e[0m
            \e[35m       @@@@         \e[0m
            \e[35m      @@@@@@        \e[0m
            \e[35m     @@@  @@@       \e[0m
            \e[35m    @@@    @@@      \e[0m
            \e[35m   @@@      @@@     \e[0m
            \e[35m  @@@   @@   @@@    \e[0m
            \e[35m   @@@  @@  @@@     \e[0m
            \e[35m    @@@ @@ @@@      \e[0m
            \e[35m     @@@@@@@        \e[0m
            \e[35m      @@@@@         \e[0m
            \e[35m       @@@          \e[0m
            \e[35m        @           \e[0m
            """)

            Mix.shell().info([
              IO.ANSI.format([:green, :bright, "  ✓ AlCheck installed successfully!\n"])
            ])

            Mix.shell().info("  Run 'check' from anywhere.\n")
            Mix.shell().info("  Examples:")
            Mix.shell().info("    check              # Run all checks")
            Mix.shell().info("    check --fast       # Run fast checks only")
            Mix.shell().info("    check --only test  # Run specific checks")
            Mix.shell().info("    check --init       # Create .check.json")
            Mix.shell().info("    check -v           # Show version\n")

          {:error, reason} ->
            CheckEscript.Spinner.stop(spinner2)
            Mix.raise("Failed to install escript: #{reason}")
        end

      {:error, reason} ->
        CheckEscript.Spinner.stop(spinner)
        Mix.raise("Failed to build escript: #{reason}")
    end
  end

  defp get_check_path do
    # If running from a project that has al_check as a dependency
    case Mix.Project.deps_paths()[:al_check] do
      nil ->
        # Running from within al_check itself
        File.cwd!()

      path ->
        # Running from a parent project
        path
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

  defp install_escript(path) do
    # First, check if escript was built
    escript_path = Path.join([path, "scripts", "check"])

    if File.exists?(escript_path) do
      case System.cmd("mix", ["escript.install", "--force", escript_path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, output}
      end
    else
      {:error, "Escript not found at #{escript_path}"}
    end
  end
end
