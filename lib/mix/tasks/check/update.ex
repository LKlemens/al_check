defmodule Mix.Tasks.Check.Update do
  use Mix.Task

  @shortdoc "Updates al_check dep, rebuilds and reinstalls the escript"

  @moduledoc """
  Updates the al_check dependency and reinstalls the check escript.

  ## Usage

      mix check.update

  Runs the commands defined in `"update"` in `.check.json`, or defaults to:

      mix deps.update al_check
      mix check.install

  ## Configuration

  Customize the update steps in `.check.json`:

      "update": [
        "mix deps.update al_check",
        "mix check.install",
        "asdf reshim"
      ]

  Add the appropriate reshim command for your version manager:
    - asdf:  `"asdf reshim"`
    - mise:  `"mise reshim"`
    - rtx:   `"rtx reshim"`
    - nix:   no reshim needed
  """

  @default_update ["mix deps.update al_check", "mix check.install"]

  @spec run([String.t()]) :: :ok
  def run(_args) do
    commands = load_update_commands()

    IO.puts("Updating check...\n")

    Enum.each(commands, &run_step/1)

    Mix.shell().info([IO.ANSI.format([:green, "✓ Update complete\n"])])

    if commands == @default_update do
      Mix.shell().info([
        IO.ANSI.format([
          :yellow,
          "Tip: Add reshim to \"update\" in .check.json if you use asdf/mise/rtx"
        ])
      ])
    end
  end

  defp run_step(cmd) do
    spinner = Check.Spinner.start(cmd)

    {output, status} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)

    Check.Spinner.stop(spinner)

    if status == 0 do
      Mix.shell().info([IO.ANSI.format([:green, "✓ #{cmd}"])])
    else
      Mix.shell().info(output)
      Mix.raise("Failed: #{cmd}")
    end
  end

  defp load_update_commands do
    case Check.Config.load() do
      {:ok, config} when is_map_key(config, "update") -> config["update"]
      _ -> @default_update
    end
  end
end
