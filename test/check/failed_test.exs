defmodule Check.FailedTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Check.Failed

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

  describe "extract_from_output/1" do
    test "extracts test failure locations" do
      output = """
        1) test something works (MyApp.SomeTest)
           test/my_app/some_test.exs:42
           Assertion failed
      """

      assert Failed.extract_from_output(output) == ["test/my_app/some_test.exs:42"]
    end

    test "extracts multiple failures" do
      output = """
        1) test first thing (MyApp.FooTest)
           test/my_app/foo_test.exs:10
           Assertion failed

        2) test second thing (MyApp.BarTest)
           test/my_app/bar_test.exs:20
           Assertion failed
      """

      result = Failed.extract_from_output(output)
      assert "test/my_app/foo_test.exs:10" in result
      assert "test/my_app/bar_test.exs:20" in result
    end

    test "returns empty for passing output" do
      output = "10 tests, 0 failures"
      assert Failed.extract_from_output(output) == []
    end

    test "extracts warning locations" do
      output = "└─ test/my_app/some_test.exs:16:5: MyApp.SomeTest.\"test name\"/1\n"
      assert "test/my_app/some_test.exs:16" in Failed.extract_from_output(output)
    end

    test "extracts both failures and warnings" do
      output = """
        1) test something (MyApp.FooTest)
           test/my_app/foo_test.exs:10
           Assertion failed

      └─ test/my_app/bar_test.exs:20:5: MyApp.BarTest."test other"/1
      """

      result = Failed.extract_from_output(output)
      assert "test/my_app/foo_test.exs:10" in result
      assert "test/my_app/bar_test.exs:20" in result
    end

    test "returns empty when no matches" do
      assert Failed.extract_from_output("no warnings here") == []
    end

    test "extracts doctest failures" do
      output = """
        1) doctest MyModule.some_function/1 (MyModule.DocTest)
           test/my_module_test.exs:5
           Doctest failed
      """

      assert Failed.extract_from_output(output) == ["test/my_module_test.exs:5"]
    end

    test "extracts property-based test failures" do
      output = """
        1) property generates valid output (MyModule.PropTest)
           test/my_module_test.exs:15
           Counterexample found
      """

      assert Failed.extract_from_output(output) == ["test/my_module_test.exs:15"]
    end
  end

  describe "detect_warnings_in_output/1" do
    test "detects warning: in output" do
      assert Failed.detect_warnings_in_output("lib/foo.ex:10: warning: unused variable")
    end

    test "false when no warnings" do
      refute Failed.detect_warnings_in_output("all good")
    end
  end

  describe "coverage_threshold_failure?/1" do
    test "detects coverage threshold failure with passing tests" do
      output = "10 tests, 0 failures\nExpected minimum coverage of 90%, got 50%"
      assert Failed.coverage_threshold_failure?(output)
    end

    test "false when tests actually failed" do
      output = "10 tests, 3 failures\nExpected minimum coverage of 90%, got 50%"
      refute Failed.coverage_threshold_failure?(output)
    end

    test "false when no coverage message" do
      refute Failed.coverage_threshold_failure?("10 tests, 0 failures")
    end

    test "detects alternative ExCoveralls threshold message" do
      output = "10 tests, 0 failures\nCoverage test failed, threshold not met"
      assert Failed.coverage_threshold_failure?(output)
    end
  end

  describe "save/1" do
    test "saves failed tests to file" do
      ExUnit.CaptureIO.capture_io(fn ->
        Failed.save(["test/foo_test.exs:10", "test/bar_test.exs:20"])
      end)

      content = File.read!(".check/failed_tests.txt")
      assert content =~ "test/foo_test.exs:10"
      assert content =~ "test/bar_test.exs:20"
    end

    test "does not save when list is empty" do
      output = ExUnit.CaptureIO.capture_io(fn -> Failed.save([]) end)
      assert output == ""
    end
  end

  describe "save_test_args/1" do
    test "saves test args to file" do
      Failed.save_test_args("--exclude slow")
      assert File.read!(".check/test_args.txt") == "--exclude slow"
    end

    test "saves default when nil" do
      Failed.save_test_args(nil)
      assert File.read!(".check/test_args.txt") == "--warnings-as-errors"
    end
  end

  describe "extract/0" do
    @tag :tmp_dir
    test "returns empty when no check_tests.txt", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        assert Failed.extract() == []
      after
        File.cd!(original_dir)
      end
    end
  end

  describe "run/1 (mocked halt)" do
    @tag :tmp_dir
    test "halts when no failed_tests.txt exists", %{tmp_dir: tmp_dir} do
      stub_halt()

      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert catch_throw(Failed.run([])) == {:halted, 1}
          end)

        assert output =~ "No failed tests found"
      after
        File.cd!(original_dir)
      end
    end

    test "prints message when failed_tests.txt is empty" do
      File.write!(".check/failed_tests.txt", "")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Failed.run([])
        end)

      assert output =~ "No failed tests to run"
    end

    test "runs failed tests and reports success" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        assert "test" in args
        assert "test/foo_test.exs:10" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["all tests passed"]
        ])
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Failed.run([])
        end)

      assert output =~ "Running 1 failed test(s)"
      assert output =~ "All previously failed tests now pass"
    end

    test "runs failed tests and reports failure" do
      stub_halt()
      File.write!(".check/failed_tests.txt", "test/bar_test.exs:20")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "echo 'failure' && exit 1"]
        ])
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          catch_throw(Failed.run([]))
        end)

      assert output =~ "Running 1 failed test(s)"
      assert output =~ "Some tests still failing"
    end

    test "passes repeat flag to test command" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        assert "--repeat-until-failure" in args
        assert "5" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run(repeat: 5)
      end)
    end

    test "adds --export-coverage failed when saved args have --cover" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--cover")

      expect(Check.Port, :open, fn "mix", args ->
        assert "--cover" in args
        assert "--export-coverage" in args
        assert "failed" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run([])
      end)
    end
  end

  describe "coverage on pass" do
    defp passing_port do
      expect(Check.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)
    end

    defp native_coverage, do: %{mod: :native, limit: nil, html: false}

    test "--all-failed shows coverage report on pass" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1")
      Failed.save_test_args("--cover")
      passing_port()

      expect(Check.Coverage, :merge, fn _coverage -> :ok end)
      stub(Check.Coverage, :show_modified_files_coverage, fn -> :ok end)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run([all_failed: true], native_coverage())
      end)
    end

    test "first --failed (no still_failing) shows coverage report on pass" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1")
      Failed.save_test_args("--cover")
      passing_port()

      expect(Check.Coverage, :merge, fn _coverage -> :ok end)
      stub(Check.Coverage, :show_modified_files_coverage, fn -> :ok end)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run([failed: true], native_coverage())
      end)
    end

    test "later --failed (still_failing exists) shows info hint, not a report" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1\ntest/b.exs:2")
      File.write!(".check/still_failing.txt", "test/a.exs:1")
      Failed.save_test_args("--cover")
      passing_port()

      reject(&Check.Coverage.merge/1)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Failed.run([failed: true], native_coverage())
        end)

      assert output =~ "Run `check --all-failed`"
    end

    test "does nothing when coverage mod is disabled" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1")
      Failed.save_test_args("--warnings-as-errors")
      passing_port()

      reject(&Check.Coverage.merge/1)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run([all_failed: true], %{mod: false})
      end)
    end

    test "run/1 defaults to no coverage" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1")
      Failed.save_test_args("--warnings-as-errors")
      passing_port()

      reject(&Check.Coverage.merge/1)

      ExUnit.CaptureIO.capture_io(fn -> Failed.run([]) end)
    end
  end

  describe "still_failing.txt" do
    test "on success deletes still_failing.txt" do
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      File.write!(".check/still_failing.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn -> Failed.run(failed: true) end)

      refute File.exists?(".check/still_failing.txt")
    end

    test "on failure writes still_failing.txt" do
      stub_halt()
      File.write!(".check/failed_tests.txt", "test/a.exs:1\ntest/b.exs:2")
      Failed.save_test_args("--warnings-as-errors")

      # simulate output where only test/a.exs:1 fails
      test_output =
        "  1) test something (MyTest)\n     test/a.exs:1\n     Assertion failed\n"

      expect(Check.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "printf '#{test_output}' && exit 1"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        catch_throw(Failed.run(failed: true))
      end)

      assert File.exists?(".check/still_failing.txt")
      content = File.read!(".check/still_failing.txt")
      assert content =~ "test/a.exs:1"
    end

    test "--failed reads from still_failing.txt when it exists" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1\ntest/b.exs:2")
      File.write!(".check/still_failing.txt", "test/a.exs:1")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        # should only have test/a.exs:1 from still_failing, not test/b.exs:2
        assert "test/a.exs:1" in args
        refute "test/b.exs:2" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn -> Failed.run(failed: true) end)
    end

    test "--all-failed reads from failed_tests.txt" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1\ntest/b.exs:2")
      File.write!(".check/still_failing.txt", "test/a.exs:1")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        # should have both from failed_tests.txt
        assert "test/a.exs:1" in args
        assert "test/b.exs:2" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn -> Failed.run(all_failed: true) end)
    end

    test "--failed falls back to failed_tests.txt when no still_failing" do
      File.write!(".check/failed_tests.txt", "test/a.exs:1")
      Failed.save_test_args("--warnings-as-errors")

      expect(Check.Port, :open, fn "mix", args ->
        assert "test/a.exs:1" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn -> Failed.run(failed: true) end)
    end
  end
end
