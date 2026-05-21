defmodule CheckEscript.UITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CheckEscript.UI

  describe "format_task_status/2" do
    test "running with test counts" do
      assert UI.format_task_status(:running, {50, 0}) == {"•", :yellow, "[RUNNING - 50 tests]"}
    end

    test "running without test counts" do
      assert UI.format_task_status(:running, nil) == {"•", :yellow, "[RUNNING]"}
    end

    test "running with zero tests" do
      assert UI.format_task_status(:running, {0, 0}) == {"•", :yellow, "[RUNNING]"}
    end

    test "success with test counts" do
      assert UI.format_task_status(0, {100, 0}) == {"✓", :green, "[OK - 100 tests]"}
    end

    test "success without test counts" do
      assert UI.format_task_status(0, nil) == {"✓", :green, "[OK]"}
    end

    test "failure with test failures" do
      assert UI.format_task_status(1, {100, 5}) == {"✗", :red, "[FAILED - 5/100 tests]"}
    end

    test "warnings with test counts" do
      assert UI.format_task_status(:warnings, {50, 0}) == {"!", :yellow, "[WARNINGS - 50 tests]"}
    end

    test "warnings without test counts" do
      assert UI.format_task_status(:warnings, nil) == {"!", :yellow, "[WARNINGS]"}
    end

    test "failure with zero failures but non-zero status" do
      assert UI.format_task_status(1, {100, 0}) == {"✗", :red, "[FAILED - 100 tests]"}
    end

    test "failure without test counts" do
      assert UI.format_task_status(1, nil) == {"✗", :red, "[FAILED]"}
    end
  end

  describe "update_task_line/5" do
    test "outputs ANSI escape sequences" do
      output = capture_io(fn -> UI.update_task_line(0, "Format", 0, 1, nil) end)
      assert output =~ "Format"
      assert output =~ "OK"
    end

    test "shows FAILED for non-zero status" do
      output = capture_io(fn -> UI.update_task_line(0, "Credo", 1, 1, nil) end)
      assert output =~ "FAILED"
    end

    test "shows WARNINGS for :warnings status" do
      output = capture_io(fn -> UI.update_task_line(0, "Tests (1/2)", :warnings, 1, {10, 0}) end)
      assert output =~ "WARNINGS"
    end

    test "shows test counts in OK" do
      output = capture_io(fn -> UI.update_task_line(0, "Tests (1/2)", 0, 1, {50, 0}) end)
      assert output =~ "50 tests"
    end
  end

  describe "update_loop/4" do
    test "updates and stops on :stop message" do
      {:ok, agent} = Agent.start_link(fn -> %{"partition_1_total" => 42, "partition_1_failures" => 0} end)

      pid =
        spawn(fn ->
          capture_io(fn ->
            UI.update_loop(0, "Tests (1/2)", 1, agent)
          end)
        end)

      # Let it tick once
      Process.sleep(100)
      send(pid, :stop)
      Process.sleep(50)
      refute Process.alive?(pid)
      Agent.stop(agent)
    end

    test "handles non-test task names" do
      {:ok, agent} = Agent.start_link(fn -> %{} end)

      pid =
        spawn(fn ->
          capture_io(fn ->
            UI.update_loop(0, "Formatting", 1, agent)
          end)
        end)

      Process.sleep(100)
      send(pid, :stop)
      Process.sleep(50)
      refute Process.alive?(pid)
      Agent.stop(agent)
    end
  end
end
