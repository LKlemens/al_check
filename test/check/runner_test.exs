defmodule CheckEscript.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CheckEscript.Runner

  describe "run_check/3" do
    test "quiet mode returns output and status" do
      {status, output} = Runner.run_check("echo", ["hello"], false)
      assert status == 0
      assert String.trim(output) == "hello"
    end

    test "quiet mode captures failure status" do
      {status, _output} = Runner.run_check("sh", ["-c", "exit 1"], false)
      assert status == 1
    end

    test "quiet mode captures stderr" do
      {status, output} = Runner.run_check("sh", ["-c", "echo err >&2"], false)
      assert status == 0
      assert output =~ "err"
    end

    test "verbose mode streams to stdout" do
      io =
        capture_io(fn ->
          {status, output} = Runner.run_check("echo", ["verbose_test"], true)
          send(self(), {:result, status, output})
        end)

      assert io =~ "verbose_test"
      assert_received {:result, 0, output}
      assert output =~ "verbose_test"
    end
  end

  describe "stream_port_output/1" do
    test "streams and returns exit status" do
      port =
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["stream_test"]
        ])

      io = capture_io(fn -> send(self(), Runner.stream_port_output(port)) end)
      assert io =~ "stream_test"
      assert_received 0
    end

    test "returns non-zero for failing command" do
      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "exit 42"]
        ])

      capture_io(fn -> send(self(), Runner.stream_port_output(port)) end)
      assert_received 42
    end
  end

  describe "determine_final_status/2" do
    test "returns :warnings when status 0 with warnings" do
      assert Runner.determine_final_status(0, "warning: unused") == :warnings
    end

    test "returns :warnings when status non-zero but tests pass with warnings" do
      output = "10 tests, 0 failures\nwarning: unused"
      assert Runner.determine_final_status(1, output) == :warnings
    end

    test "returns 0 for coverage threshold failure" do
      output = "10 tests, 0 failures\nExpected minimum coverage"
      assert Runner.determine_final_status(1, output) == 0
    end

    test "passes through status 0 with clean output" do
      assert Runner.determine_final_status(0, "all good") == 0
    end

    test "passes through failure status with real failures" do
      assert Runner.determine_final_status(1, "10 tests, 3 failures") == 1
    end

    test "does not flag warnings when tests actually fail" do
      output = "10 tests, 3 failures\nwarning: unused"
      assert Runner.determine_final_status(1, output) == 1
    end
  end
end
