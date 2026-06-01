defmodule Check.PartitionsTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  setup :verify_on_exit!

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "run_for_all/2" do
    test "runs command for each partition" do
      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 echo hello"],
                              _opts ->
        {"", 0}
      end)

      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=2 echo hello"],
                              _opts ->
        {"", 0}
      end)

      output = capture_io(fn -> Check.Partitions.run_for_all("echo hello", 2) end)

      assert output =~ "Running across 2 partition(s)"
      assert output =~ "MIX_ENV=test MIX_TEST_PARTITION=1 echo hello"
      assert output =~ "MIX_ENV=test MIX_TEST_PARTITION=2 echo hello"
      assert output =~ "✓ Partition 1/2"
      assert output =~ "✓ Partition 2/2"
      assert output =~ "All 2 partition(s) done"
    end

    test "reports failure and halts" do
      stub_halt()

      expect(System, :cmd, fn "sh", ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 exit 1"], _opts ->
        {"error output", 1}
      end)

      output =
        capture_io(fn ->
          catch_throw(Check.Partitions.run_for_all("exit 1", 1))
        end)

      assert output =~ "✗ Partition 1/1"
      assert output =~ "1 partition(s) failed"
    end

    test "continues all partitions even if one fails" do
      stub_halt()

      expect(System, :cmd, fn "sh", ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 cmd"], _opts ->
        {"fail", 1}
      end)

      expect(System, :cmd, fn "sh", ["-c", "MIX_ENV=test MIX_TEST_PARTITION=2 cmd"], _opts ->
        {"", 0}
      end)

      output =
        capture_io(fn ->
          catch_throw(Check.Partitions.run_for_all("cmd", 2))
        end)

      assert output =~ "✗ Partition 1/2"
      assert output =~ "✓ Partition 2/2"
      assert output =~ "1 partition(s) failed"
    end

    test "single partition" do
      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 mix ecto.setup"],
                              _opts ->
        {"", 0}
      end)

      output = capture_io(fn -> Check.Partitions.run_for_all("mix ecto.setup", 1) end)

      assert output =~ "All 1 partition(s) done"
    end
  end
end
