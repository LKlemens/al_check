defmodule Check.WatchTest do
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureIO

  setup :verify_on_exit!

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "run/0" do
    test "halts when no partition files exist" do
      stub_halt()
      stub(Path, :wildcard, fn ".check/test_partition_*.txt" -> [] end)

      output =
        capture_io(fn ->
          catch_throw(Check.Watch.run())
        end)

      assert output =~ "No test partition files found"
    end

    test "starts watching when partition files exist" do
      stub_halt()
      stub(Path, :wildcard, fn ".check/test_partition_*.txt" -> [".check/test_partition_1.txt"] end)
      stub(File, :mkdir_p!, fn _ -> :ok end)
      stub(File, :write!, fn _, _ -> :ok end)

      expect(Check.Port, :open, fn "tail", args ->
        assert "-f" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["watching..."]
        ])
      end)

      output =
        capture_io(fn ->
          Check.Watch.run()
        end)

      assert output =~ "Watching"
      assert output =~ "test partition file(s)"
      assert output =~ "watching..."
    end
  end
end
