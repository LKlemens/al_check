defmodule CheckEscript.TasksTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Tasks

  describe "has_test_tasks?/1" do
    test "true when partition tasks present" do
      tasks = [{"Tests (1/3)", "sh", ["-c", "mix test"], 1, 3}]
      assert Tasks.has_test_tasks?(tasks)
    end

    test "false when no partition tasks" do
      tasks = [{"Formatting", "mix", ["format"]}]
      refute Tasks.has_test_tasks?(tasks)
    end

    test "false for empty list" do
      refute Tasks.has_test_tasks?([])
    end
  end

  describe "test_runner_cmd/2" do
    test "native returns test with --cover" do
      assert Tasks.test_runner_cmd(:native, 1) == {"test", " --cover"}
    end

    test "coveralls returns coveralls" do
      assert Tasks.test_runner_cmd(:coveralls, 1) == {"coveralls", ""}
    end

    test "false returns plain test" do
      assert Tasks.test_runner_cmd(false, 1) == {"test", ""}
    end
  end

  describe "test_procs/1" do
    test "returns at least 1" do
      assert Tasks.test_procs(1000) >= 1
    end

    test "divides schedulers by partitions" do
      schedulers = :erlang.system_info(:schedulers_online)
      assert Tasks.test_procs(2) == floor(schedulers / 2)
    end
  end

  describe "build_test_cmd/5" do
    test "basic test command" do
      coverage = %{mod: false, limit: nil, html: false}
      cmd = Tasks.build_test_cmd(nil, nil, nil, 3, coverage)
      assert cmd == "mix test --warnings-as-errors --partitions 3"
    end

    test "with coverage" do
      coverage = %{mod: :native, limit: 80, html: false}
      cmd = Tasks.build_test_cmd(nil, nil, nil, 3, coverage)
      assert cmd =~ "mix test --cover"
    end

    test "with dir and custom args" do
      coverage = %{mod: false, limit: nil, html: false}
      cmd = Tasks.build_test_cmd("test/foo", "--exclude slow", nil, 2, coverage)
      assert cmd =~ "test/foo"
      assert cmd =~ "--exclude slow"
      assert cmd =~ "--partitions 2"
    end

    test "with repeat" do
      coverage = %{mod: false, limit: nil, html: false}
      cmd = Tasks.build_test_cmd(nil, nil, 10, 3, coverage)
      assert cmd =~ "--repeat-until-failure 10"
    end
  end
end
