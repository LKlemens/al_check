defmodule Mix.Tasks.Check.InstallTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mix.Tasks.Check.Install

  setup :verify_on_exit!

  describe "run/1" do
    test "builds and installs escript successfully" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "mix", ["escript.build"], _opts -> {"", 0} end)

      expect(System, :cmd, fn "mix", ["escript.install", "--force", path], _opts ->
        assert path =~ "scripts/check"
        {"", 0}
      end)

      # Create the escript file so install_escript finds it
      File.mkdir_p!("scripts")
      File.write!("scripts/check", "fake escript")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Install.run([])
        end)

      assert output =~ "AlCheck installed successfully"
      assert output =~ "check"
    end

    test "reports build failure" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "mix", ["escript.build"], _opts -> {"build failed", 1} end)

      assert_raise Mix.Error, ~r/Failed to build escript/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Install.run([])
        end)
      end
    end

    test "reports deps.get failure" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"deps error", 1} end)

      assert_raise Mix.Error, ~r/Failed to build escript/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Install.run([])
        end)
      end
    end
  end
end
