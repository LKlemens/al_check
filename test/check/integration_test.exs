defmodule Check.IntegrationTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  @moduletag :integration

  setup :verify_on_exit!

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

    test "partition task with warnings returns :warnings status" do
      tasks = [
        {"Tests (1/1)", "sh",
         ["-c", "echo 'warning: unused\n.\n\nFinished in 0.1s\n1 test, 0 failures'"], 1, 1}
      ]

      capture_io(fn ->
        {results, _} = Check.Runner.run_checks(tasks, nil, "mix test", 10, false)
        send(self(), {:results, results})
      end)

      assert_received {:results, [{"Tests (1/1)", :warnings, _output}]}
    end
  end

  describe "runner - determine_final_status" do
    test "returns :warnings when tests pass but warnings detected (status 0)" do
      output = "10 tests, 0 failures\nwarning: unused variable"
      assert Check.Runner.determine_final_status(0, output) == :warnings
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
      File.mkdir_p!(".check")
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
      File.rm(".check/.format_failed")

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

      # ensure no partition files
      Path.wildcard(".check/test_partition_*.txt") |> Enum.each(&File.rm/1)

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
      tasks = [{"Modified Tests", :builtin, ["modified_tests"]}]

      output =
        capture_io(fn ->
          {results, _seconds} = Check.Runner.run_checks(tasks, nil, "", 10, false)
          send(self(), {:results, results})
        end)

      assert_received {:results, [{"Modified Tests", 0, ""}]}
      assert output =~ "Running code quality checks"
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
end
