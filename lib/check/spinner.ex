defmodule Check.Spinner do
  @moduledoc "Animated spinner for long-running operations."

  @frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  def start(label \\ "Running") do
    if quiet?() do
      spawn_link(fn -> receive do: (:stop -> :ok) end)
    else
      spawn_link(fn -> loop(label, 0) end)
    end
  end

  def stop(pid) do
    send(pid, :stop)

    if not quiet?() do
      IO.write("\e[2K\r")
    end
  end

  defp quiet?, do: Application.get_env(:al_check, :quiet, false)

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
