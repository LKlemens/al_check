defmodule Check.TasksTest do
  use ExUnit.Case, async: true

  alias Check.Tasks

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

  describe "test_runner_cmd/1" do
    test "native returns test with --cover" do
      assert Tasks.test_runner_cmd(:native) == {"test", " --cover"}
    end

    test "coveralls returns coveralls" do
      assert Tasks.test_runner_cmd(:coveralls) == {"coveralls", ""}
    end

    test "false returns plain test" do
      assert Tasks.test_runner_cmd(false) == {"test", ""}
    end
  end

  describe "test_procs/1" do
    test "returns at least 1" do
      assert Tasks.test_procs(1000) >= 1
    end

    test "divides schedulers by partitions" do
      schedulers = :erlang.system_info(:schedulers_online)
      # Mirror the implementation's floor-of-1: on a single-scheduler host
      # floor(1 / 2) == 0, but test_procs/1 never returns less than 1.
      assert Tasks.test_procs(2) == max(floor(schedulers / 2), 1)
    end
  end

  describe "build_test_cmd/5" do
    test "basic test command" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      cmd = Tasks.build_test_cmd(nil, nil, nil, 3, coverage)
      assert cmd == "mix test --warnings-as-errors --partitions 3"
    end

    test "with coverage" do
      coverage = %{mod: :native, limit: 80, html: false, baseline_cmd: nil}
      cmd = Tasks.build_test_cmd(nil, nil, nil, 3, coverage)
      assert cmd =~ "mix test --cover"
      assert cmd =~ "--partitions 3"
    end

    test "with dir and custom args" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      cmd = Tasks.build_test_cmd("test/foo", "--exclude slow", nil, 2, coverage)
      assert cmd =~ "test/foo"
      assert cmd =~ "--exclude slow"
      assert cmd =~ "--partitions 2"
    end

    test "with repeat" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      cmd = Tasks.build_test_cmd(nil, nil, 10, 3, coverage)
      assert cmd =~ "--repeat-until-failure 10"
    end
  end

  describe "define/7" do
    test "mock mode returns predefined checks" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      tasks = Tasks.define(true, 2, nil, nil, nil, %{}, coverage)

      assert Map.has_key?(tasks, :format)
      assert Map.has_key?(tasks, :compile)
      assert Map.has_key?(tasks, :credo)
      # test partitions are added
      assert Map.has_key?(tasks, :test_1)
      assert Map.has_key?(tasks, :test_2)
    end

    test "generates correct number of test partitions" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      tasks = Tasks.define(true, 4, nil, nil, nil, %{}, coverage)

      for i <- 1..4 do
        assert Map.has_key?(tasks, String.to_atom("test_#{i}"))
      end

      refute Map.has_key?(tasks, :test_5)
    end

    test "zero partitions generates no test tasks" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      tasks = Tasks.define(true, 0, nil, nil, nil, %{}, coverage)

      refute Map.has_key?(tasks, :test_1)
      assert Map.has_key?(tasks, :format)
    end

    test "uses custom checks from config" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      config = %{"checks" => %{"lint" => %{"name" => "Lint", "run" => "mix lint"}}}

      ExUnit.CaptureIO.capture_io(fn ->
        tasks = Tasks.define(false, 0, nil, nil, nil, config, coverage)
        send(self(), {:tasks, tasks})
      end)

      assert_received {:tasks, tasks}
      assert Map.has_key?(tasks, :lint)
      refute Map.has_key?(tasks, :format)
    end

    test "warns and drops test key from custom checks" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      config = %{
        "checks" => %{
          "test" => %{"name" => "Test", "run" => "mix test"},
          "lint" => %{"name" => "Lint", "run" => "mix lint"}
        }
      }

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            tasks = Tasks.define(false, 0, nil, nil, nil, config, coverage)
            send(self(), {:tasks, tasks})
          end)
        end)

      assert output =~ "\"test\" in checks is ignored"
      assert_received {:tasks, tasks}
      refute Map.has_key?(tasks, :test)
      assert Map.has_key?(tasks, :lint)
    end

    test "resolves {partition} placeholder in test_args" do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      ExUnit.CaptureIO.capture_io(fn ->
        tasks =
          Tasks.define(
            false,
            2,
            nil,
            "--cover --export-coverage partition-{partition}",
            nil,
            %{},
            coverage
          )

        {_name, "sh", ["-c", cmd], 1, 2} = tasks[:test_1]
        send(self(), {:cmd1, cmd})

        {_name, "sh", ["-c", cmd2], 2, 2} = tasks[:test_2]
        send(self(), {:cmd2, cmd2})
      end)

      assert_received {:cmd1, cmd}
      assert cmd =~ "--export-coverage partition-1"

      assert_received {:cmd2, cmd2}
      assert cmd2 =~ "--export-coverage partition-2"
    end
  end

  describe "select/4" do
    setup do
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}
      tasks = Tasks.define(true, 2, nil, nil, nil, %{}, coverage)
      %{tasks: tasks}
    end

    test "selects all when no flags", %{tasks: tasks} do
      selected = Tasks.select(tasks, [], 2, %{})
      assert length(selected) == map_size(tasks)
    end

    test "fast mode selects only fast checks", %{tasks: tasks} do
      selected = Tasks.select(tasks, [fast: true], 2, %{})
      names = Enum.map(selected, &elem(&1, 0))
      assert "Formatting" in names
      assert "Compile" in names
      refute Enum.any?(names, &String.starts_with?(&1, "Tests"))
    end

    test "only selects specified checks", %{tasks: tasks} do
      selected = Tasks.select(tasks, [only: "format"], 2, %{})
      assert length(selected) == 1
      assert elem(hd(selected), 0) == "Formatting"
    end

    test "only test expands to partitions", %{tasks: tasks} do
      selected = Tasks.select(tasks, [only: "test"], 2, %{})
      assert length(selected) == 2
      names = Enum.map(selected, &elem(&1, 0))
      assert "Tests (1/2)" in names
      assert "Tests (2/2)" in names
    end

    test "warns on unknown check", %{tasks: tasks} do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          # include a valid check so the list isn't empty (which would call System.halt)
          Tasks.select(tasks, [only: "nonexistent,format"], 2, %{})
        end)

      assert output =~ "Unknown check"
    end
  end

  describe "cap_partitions/2" do
    @tag :tmp_dir
    test "caps when fewer files than partitions", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "one_test.exs"), "")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = Tasks.cap_partitions(3, tmp_dir)
          send(self(), {:result, result})
        end)

      assert_received {:result, 1}
      assert output =~ "Not enough test files"
    end

    @tag :tmp_dir
    test "returns 0 when no test files", %{tmp_dir: tmp_dir} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = Tasks.cap_partitions(3, tmp_dir)
          send(self(), {:result, result})
        end)

      assert_received {:result, 0}
      assert output =~ "No test files found"
    end

    @tag :tmp_dir
    test "counts files across multiple dirs", %{tmp_dir: tmp_dir} do
      dir_a = Path.join(tmp_dir, "a")
      dir_b = Path.join(tmp_dir, "b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_a, "foo_test.exs"), "")
      File.write!(Path.join(dir_b, "bar_test.exs"), "")

      ExUnit.CaptureIO.capture_io(fn ->
        result = Tasks.cap_partitions(3, "#{dir_a} #{dir_b}")
        send(self(), {:result, result})
      end)

      assert_received {:result, 2}
    end

    @tag :tmp_dir
    test "handles single dir as string", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "one_test.exs"), "")

      result = Tasks.cap_partitions(1, tmp_dir)
      assert result == 1
    end

    @tag :tmp_dir
    test "keeps partitions when enough files", %{tmp_dir: tmp_dir} do
      for i <- 1..5 do
        File.write!(Path.join(tmp_dir, "test_#{i}_test.exs"), "")
      end

      result = Tasks.cap_partitions(3, tmp_dir)
      assert result == 3
    end
  end
end
