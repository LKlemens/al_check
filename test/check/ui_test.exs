defmodule CheckEscript.UITest do
  use ExUnit.Case, async: true

  alias CheckEscript.UI

  describe "format_task_status/2" do
    test "running with test counts" do
      assert UI.format_task_status(:running, {50, 0}) == {"•", :yellow, "[RUNNING - 50 tests]"}
    end

    test "running without test counts" do
      assert UI.format_task_status(:running, nil) == {"•", :yellow, "[RUNNING]"}
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
end
