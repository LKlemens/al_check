defmodule Mix.Tasks.Check.UpdateTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mix.Tasks.Check.Update

  setup :verify_on_exit!

  describe "run/1" do
    test "runs default update commands" do
      expect(System, :cmd, fn "sh", ["-c", "mix deps.update al_check"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "sh", ["-c", "mix check.install"], _opts -> {"", 0} end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Update.run([])
        end)

      assert output =~ "Updating check"
      assert output =~ "Update complete"
      # default commands → show tip
      assert output =~ "Tip"
      assert output =~ "asdf/mise/rtx"
    end

    test "fails on command error" do
      expect(System, :cmd, fn "sh", ["-c", "mix deps.update al_check"], _opts ->
        {"error output", 1}
      end)

      assert_raise Mix.Error, ~r/Failed/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Update.run([])
        end)
      end
    end

    test "runs custom commands from config" do
      config = %{"update" => ["echo step1", "echo step2"]}
      expect(Check.Config, :load, fn -> {:ok, config} end)

      expect(System, :cmd, fn "sh", ["-c", "echo step1"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "sh", ["-c", "echo step2"], _opts -> {"", 0} end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Update.run([])
        end)

      assert output =~ "Update complete"
      # custom commands → no tip
      refute output =~ "Tip"
    end
  end
end
