defmodule Check.SpinnerTest do
  use ExUnit.Case, async: true

  alias Check.Spinner

  test "start returns a pid" do
    pid = Spinner.start("Testing")
    assert is_pid(pid)
    assert Process.alive?(pid)
    Spinner.stop(pid)
    Process.sleep(50)
    refute Process.alive?(pid)
  end

  test "does not write spinner output when stdout is not a tty" do
    # Captured IO is not an interactive terminal, so the spinner must stay silent
    # rather than leaving `⠙ Loading` escape leftovers in piped/CI logs.
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        pid = Spinner.start("Loading")
        Process.sleep(150)
        Spinner.stop(pid)
      end)

    assert output == ""
  end
end
