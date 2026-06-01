defmodule Check.Spinner do
  @moduledoc "Animated spinner for long-running operations."

  @frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  def start(label \\ "Running") do
    spawn_link(fn -> loop(label, 0) end)
  end

  def stop(pid) do
    send(pid, :stop)
    # clear the spinner line
    IO.write("\e[2K\r")
  end

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
