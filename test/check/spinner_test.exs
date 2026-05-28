defmodule CheckEscript.SpinnerTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Spinner

  test "start returns a pid" do
    pid = Spinner.start("Testing")
    assert is_pid(pid)
    assert Process.alive?(pid)
    Spinner.stop(pid)
    Process.sleep(50)
    refute Process.alive?(pid)
  end

  test "stop clears spinner line" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        pid = Spinner.start("Loading")
        Process.sleep(150)
        Spinner.stop(pid)
      end)

    # spinner should have printed something
    assert output =~ "Loading"
  end
end
