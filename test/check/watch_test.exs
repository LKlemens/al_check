defmodule CheckEscript.WatchTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  setup :verify_on_exit!

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "run/0" do
    test "halts when no partition files exist" do
      stub_halt()
      Path.wildcard(".check/test_partition_*.txt") |> Enum.each(&File.rm/1)

      output =
        capture_io(fn ->
          catch_throw(CheckEscript.Watch.run())
        end)

      assert output =~ "No test partition files found"
    end

    test "starts watching when partition files exist" do
      stub_halt()
      File.mkdir_p!(".check")
      File.write!(".check/test_partition_1.txt", "test output")

      # Mock Port.open to return a port that exits immediately
      expect(CheckEscript.Port, :open, fn "tail", args ->
        assert "-f" in args
        # Return a port that just exits
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["watching..."]
        ])
      end)

      output =
        capture_io(fn ->
          CheckEscript.Watch.run()
        end)

      assert output =~ "Watching"
      assert output =~ "test partition file(s)"
      assert output =~ "watching..."
    after
      File.rm(".check/test_partition_1.txt")
    end
  end
end
