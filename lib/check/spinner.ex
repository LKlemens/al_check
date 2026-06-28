defmodule Check.Spinner do
  @moduledoc "Animated spinner for long-running operations."

  @frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  def start(label \\ "Running") do
    if animate?() do
      spawn_link(fn -> loop(label, 0) end)
    else
      spawn_link(fn -> receive do: (:stop -> :ok) end)
    end
  end

  def stop(pid) do
    send(pid, :stop)

    if animate?() do
      IO.write("\e[2K\r")
    end
  end

  # Only animate on an interactive terminal. When stdout is piped to a file or CI
  # log the cursor escapes are no-ops, so each frame would pile up as literal
  # `⠙ Running` leftovers in the log.
  defp animate?, do: not quiet?() and tty?()

  defp quiet?, do: Application.get_env(:al_check, :quiet, false)

  defp tty?, do: match?({:ok, _}, :io.columns())

  defp loop(label, frame) do
    receive do
      :stop -> :ok
    after
      100 ->
        try do
          icon = Enum.at(@frames, rem(frame, length(@frames)))
          IO.write("\e[2K\r#{icon} #{label}")
        rescue
          _ -> :ok
        end

        loop(label, frame + 1)
    end
  end
end
