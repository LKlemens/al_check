defmodule Check.IntegrationTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  @moduletag :integration

  setup :verify_on_exit!

  setup do
    fs = start_supervised!({Agent, fn -> %{} end})
    stub(File, :mkdir_p!, fn _ -> :ok end)

    stub(File, :write!, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, content))
      :ok
    end)

    stub(File, :read!, fn path -> Agent.get(fs, &Map.fetch!(&1, path)) end)

    stub(File, :read, fn path ->
      case Agent.get(fs, &Map.get(&1, path)) do
        nil -> {:error, :enoent}
        content -> {:ok, content}
      end
    end)

    stub(File, :exists?, fn path -> Agent.get(fs, &Map.has_key?(&1, path)) end)

    stub(File, :rm, fn path ->
      Agent.update(fs, &Map.delete(&1, path))
      :ok
    end)

    :ok
  end

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "mock mode - format only" do
    test "runs only format in mock mode" do
      output = capture_io(fn -> Check.main(["--only", "format", "mock"]) end)

      assert output =~ "Running code quality checks in parallel"
      assert output =~ "Formatting"
      assert output =~ "All checks passed"
    end

    test "runs with verbose flag" do
      output = capture_io(fn -> Check.main(["--only", "format", "--verbose", "mock"]) end)

      assert output =~ "Format check passed"
      assert output =~ "All checks passed"
    end

    test "runs with custom partitions" do
      output =
        capture_io(fn ->
          Check.main(["--only", "format", "--partitions", "1", "mock"])
        end)

      assert output =~ "All checks passed"
    end
  end

  describe "failure flow" do
    test "reports failure details for failing checks" do
      stub_halt()

      tasks = [{"Credo Strict", "sh", ["-c", "echo 'error: bad code' && exit 1"]}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      output =
        capture_io(fn ->
          {results, seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          catch_throw(Check.Summary.print(results, seconds, tasks, coverage))
        end)

      assert output =~ "FAILURE DETAILS"
      assert output =~ "Credo Strict failed"
      assert output =~ "bad code"
    end
  end

  describe "parallel partition warning" do
    @coverage %{mod: false, limit: nil, html: false, baseline_cmd: nil}

    test "warns about per-partition config when a partition test fails" do
      stub_halt()

      tasks = [
        {"Tests (1/2)", "sh", ["-c", "echo ok"]},
        {"Tests (2/2)", "sh", ["-c", "echo 'boom' && exit 1"]}
      ]

      output =
        capture_io(fn ->
          {results, seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          catch_throw(Check.Summary.print(results, seconds, tasks, @coverage))
        end)

      assert output =~
               "Please be aware that running tests in parallel requires a tweak to your configuration"

      assert output =~ "test-partitioning.html"
    end

    test "does not warn when all partitions pass" do
      tasks = [
        {"Tests (1/2)", "sh", ["-c", "echo ok"]},
        {"Tests (2/2)", "sh", ["-c", "echo ok"]}
      ]

      output =
        capture_io(fn ->
          {results, seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          Check.Summary.print(results, seconds, tasks, @coverage)
        end)

      refute output =~ "test-partitioning.html"
      assert output =~ "All checks passed"
    end

    test "does not warn on a single-partition failure" do
      stub_halt()

      tasks = [{"Tests (1/1)", "sh", ["-c", "echo 'boom' && exit 1"]}]

      output =
        capture_io(fn ->
          {results, seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          catch_throw(Check.Summary.print(results, seconds, tasks, @coverage))
        end)

      refute output =~ "test-partitioning.html"
    end
  end

  describe "runner" do
    test "run_checks executes regular tasks in parallel" do
      tasks = [{"Echo1", "echo", ["hello"]}, {"Echo2", "echo", ["world"]}]

      output =
        capture_io(fn ->
          {results, seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          send(self(), {:results, results, seconds})
        end)

      assert_received {:results, results, seconds}
      assert length(results) == 2
      assert seconds >= 0
      Enum.each(results, fn {_name, status, _output} -> assert status == 0 end)
      assert output =~ "Running code quality checks"
    end

    test "run_checks captures failure status" do
      tasks = [{"Fail", "sh", ["-c", "exit 1"]}]

      output =
        capture_io(fn ->
          {results, _} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          send(self(), {:results, results})
        end)

      assert_received {:results, [{"Fail", 1, _}]}
      assert output =~ "FAILED"
    end

    test "verbose mode streams output" do
      tasks = [{"Echo", "echo", ["verbose_output"]}]

      output =
        capture_io(fn ->
          Check.Runner.run_checks(tasks, nil, "", 10, true)
        end)

      assert output =~ "verbose_output"
    end

    test "runs partition tasks (5-tuple)" do
      tasks = [
        {"Tests (1/1)", "sh", ["-c", "echo '.\n\nFinished in 0.1s\n1 test, 0 failures'"], 1, 1}
      ]

      output =
        capture_io(fn ->
          {results, _} = Check.Runner.run_checks(tasks, nil, "mix test", 10, false)
          send(self(), {:results, results})
        end)

      assert_received {:results, [{"Tests (1/1)", 0, _output}]}
      assert output =~ "Test command"
    end

    test "partition task with warnings-as-errors (non-zero exit) returns :warnings status" do
      tasks = [
        {"Tests (1/1)", "sh",
         ["-c", "echo 'warning: unused\n.\n\nFinished in 0.1s\n1 test, 0 failures'; exit 1"], 1,
         1}
      ]

      capture_io(fn ->
        {results, _} = Check.Runner.run_checks(tasks, nil, "mix test", 10, false)
        send(self(), {:results, results})
      end)

      assert_received {:results, [{"Tests (1/1)", :warnings, _output}]}
    end
  end

  describe "runner - determine_final_status" do
    test "returns 0 when mix exits 0 even with warnings (no --warnings-as-errors)" do
      output = "10 tests, 0 failures\nwarning: unused variable"
      assert Check.Runner.determine_final_status(0, output) == 0
    end

    test "returns :warnings when mix exits non-zero but tests pass with warnings" do
      output = "10 tests, 0 failures\nwarning: unused variable"
      assert Check.Runner.determine_final_status(1, output) == :warnings
    end

    test "returns 0 for coverage threshold failure" do
      output = "10 tests, 0 failures\nExpected minimum coverage"
      assert Check.Runner.determine_final_status(1, output) == 0
    end

    test "passes through normal exit status" do
      assert Check.Runner.determine_final_status(0, "all good") == 0
      assert Check.Runner.determine_final_status(1, "10 tests, 3 failures") == 1
    end
  end

  describe "summary - success paths" do
    test "prints success for all passing results" do
      results = [{"Format", 0, "ok"}, {"Compile", 0, "ok"}]
      tasks = [{"Format", "echo", ["ok"]}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      output = capture_io(fn -> Check.Summary.print(results, 1.5, tasks, coverage) end)

      assert output =~ "Completed in 1.5s"
      assert output =~ "All checks passed"
    end

    test "saves credo output files" do
      results = [{"Credo", 0, "credo output"}, {"Credo Strict", 0, "strict output"}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      capture_io(fn -> Check.Summary.print(results, 1.0, [], coverage) end)

      assert File.read!(".check/credo.txt") == "credo output"
      assert File.read!(".check/credo_strict.txt") == "strict output"
    end

    test "removes format failure marker on success" do
      File.write!(".check/.format_failed", "")

      results = [{"Formatting", 0, "ok"}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      capture_io(fn -> Check.Summary.print(results, 1.0, [], coverage) end)

      refute File.exists?(".check/.format_failed")
    end

    test "merges partition outputs" do
      results = [
        {"Tests (1/2)", 0, "partition 1 output"},
        {"Tests (2/2)", 0, "partition 2 output"}
      ]

      tasks = [
        {"Tests (1/2)", "sh", ["-c", "mix test"], 1, 2},
        {"Tests (2/2)", "sh", ["-c", "mix test"], 2, 2}
      ]

      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      capture_io(fn -> Check.Summary.print(results, 1.0, tasks, coverage) end)

      content = File.read!(".check/check_tests.txt")
      assert content =~ "PARTITION 1/2"
      assert content =~ "PARTITION 2/2"
    end
  end

  describe "summary - failure paths (mocked halt)" do
    test "prints failure details and halts" do
      stub_halt()

      results = [{"Format", 0, "ok"}, {"Credo", 1, "error: something bad"}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      output =
        capture_io(fn ->
          catch_throw(Check.Summary.print(results, 2.0, [], coverage))
        end)

      assert output =~ "1 check(s) failed"
      assert output =~ "FAILURE DETAILS"
      assert output =~ "Credo failed"
      assert output =~ "something bad"
    end

    test "saves format failure marker on failure" do
      stub_halt()

      results = [{"Formatting", 1, "not formatted"}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      capture_io(fn ->
        catch_throw(Check.Summary.print(results, 1.0, [], coverage))
      end)

      assert File.exists?(".check/.format_failed")
    end

    test "prints warning count for warnings-only test failures" do
      stub_halt()

      test_output = "warning: unused\nwarning: another\n10 tests, 0 failures"
      results = [{"Tests (1/1)", :warnings, test_output}]
      tasks = [{"Tests (1/1)", "sh", ["-c", "mix test"], 1, 1}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      output =
        capture_io(fn ->
          catch_throw(Check.Summary.print(results, 1.0, tasks, coverage))
        end)

      assert output =~ "warning(s) detected"
      assert output =~ "10 tests, 0 failures"
    end

    test "extracts and saves failed tests from check output" do
      stub_halt()

      test_output = """
        1) test something (MyApp.FooTest)
           test/my_app/foo_test.exs:42
           Assertion failed
      """

      results = [{"New Tests", 1, test_output}]
      coverage = %{mod: false, limit: nil, html: false, baseline_cmd: nil}

      capture_io(fn ->
        catch_throw(Check.Summary.print(results, 1.0, [], coverage))
      end)

      content = File.read!(".check/failed_tests.txt")
      assert content =~ "test/my_app/foo_test.exs:42"
    end
  end

  describe "summary - pure functions" do
    test "extract_test_summary finds summary line" do
      output = "...\n\nFinished in 0.1s\n108 tests, 3 failures, 5 excluded"
      assert Check.Summary.extract_test_summary(output) =~ "108 tests, 3 failures"
    end

    test "extract_test_summary returns fallback for no match" do
      assert Check.Summary.extract_test_summary("no summary") =~ "check_tests.txt"
    end

    test "colorize_line colors warnings yellow" do
      result = Check.Summary.colorize_line("lib/foo.ex:10: warning: unused")
      assert is_list(result)
    end

    test "colorize_line colors errors red" do
      result = Check.Summary.colorize_line("** (CompileError) error: bad")
      assert is_list(result)
    end

    test "colorize_line returns plain string for normal lines" do
      assert Check.Summary.colorize_line("normal line") == "normal line"
    end
  end

  describe "watch - early exit" do
    test "halts when no partition files exist" do
      stub_halt()
      stub(Path, :wildcard, fn ".check/test_partition_*.txt" -> [] end)

      output =
        capture_io(fn ->
          catch_throw(Check.Watch.run())
        end)

      assert output =~ "No test partition files found"
    end
  end

  describe "tasks - empty selection halt" do
    test "halts when no valid checks specified" do
      stub_halt()

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.Tasks.select(%{}, [only: "nonexistent"], 2, %{}))
        end)

      assert output =~ "No valid checks specified"
    end
  end

  describe "fix module" do
    test "extract_file_paths" do
      output = "  ┃   lib/my_app/accounts.ex:45:5\n  ┃   lib/my_app/users.ex:12:3\n"

      files = Check.Fix.extract_file_paths(output)
      assert "lib/my_app/accounts.ex" in files
      assert "lib/my_app/users.ex" in files
    end
  end

  describe "builtin checks in task flow" do
    test "builtin check runs through runner" do
      # Keep the builtin deterministic regardless of the repo's real git state:
      # report no modified test files so it warns and passes.
      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          match?(["rev-parse" | _], args) -> {"", 0}
          true -> {"", 0}
        end
      end)

      tasks = [{"Modified Tests", :builtin, ["modified_tests"]}]

      output =
        capture_io(fn ->
          {results, _seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          send(self(), {:results, results})
        end)

      # The builtin's stdout is captured and returned as its output (so the
      # status UI isn't corrupted), then reprinted below the status lines.
      assert_received {:results, [{"Modified Tests", 0, builtin_output}]}
      assert builtin_output =~ "no modified test files found"
      assert output =~ "Running code quality checks"
      assert output =~ "no modified test files found"
    end

    test "unknown builtin reports error" do
      tasks = [{"Bad Builtin", :builtin, ["nonexistent"]}]

      capture_io(fn ->
        capture_io(:stderr, fn ->
          {results, _seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          send(self(), {:results, results})
        end)
      end)

      assert_received {:results, [{"Bad Builtin", 1, ""}]}
    end
  end

  describe "coverage flag saved for --failed" do
    test "save_test_args saves exact string" do
      Check.Failed.save_test_args("--warnings-as-errors")
      assert File.read!(".check/test_args.txt") == "--warnings-as-errors"
    end

    test "save_test_args with --cover" do
      Check.Failed.save_test_args("--warnings-as-errors --cover")
      saved = File.read!(".check/test_args.txt")
      assert saved =~ "--warnings-as-errors"
      assert saved =~ "--cover"
    end

    test "--failed reads saved --cover and adds --export-coverage" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Check.Failed.save_test_args("--warnings-as-errors --cover")

      expect(Check.Port, :open, fn "mix", args ->
        assert "--cover" in args
        assert "--export-coverage" in args
        assert "failed" in args
        assert "--warnings-as-errors" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      capture_io(fn -> Check.Failed.run([]) end)
    end

    test "--failed without --cover does not add --export-coverage" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Check.Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        assert "--warnings-as-errors" in args
        refute "--cover" in args
        refute "--export-coverage" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      capture_io(fn -> Check.Failed.run([]) end)
    end
  end
end
