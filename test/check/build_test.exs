defmodule Mix.Tasks.Check.BuildTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Mix.Tasks.Check.Build

  setup :verify_on_exit!

  describe "run/1" do
    test "builds escript successfully" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "mix", ["escript.build"], _opts -> {"", 0} end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Build.run([])
        end)

      assert output =~ "Built:"
      assert output =~ "scripts/check"
      assert output =~ "Run directly"
      assert output =~ "alias check="
    end

    test "reports build failure" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"", 0} end)
      expect(System, :cmd, fn "mix", ["escript.build"], _opts -> {"build failed", 1} end)

      assert_raise Mix.Error, ~r/Failed to build escript/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Build.run([])
        end)
      end
    end

    test "reports deps.get failure" do
      expect(System, :cmd, fn "mix", ["deps.get"], _opts -> {"deps error", 1} end)

      assert_raise Mix.Error, ~r/Failed to build escript/, fn ->
        ExUnit.CaptureIO.capture_io(fn ->
          Build.run([])
        end)
      end
    end
  end
end
