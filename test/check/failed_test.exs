defmodule CheckEscript.FailedTest do
  use ExUnit.Case, async: false
  use Mimic

  alias CheckEscript.Failed

  setup :verify_on_exit!

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
    test "halts when no failed_tests.txt exists" do
      stub_halt()

      original_dir = File.cwd!()
      tmp = System.tmp_dir!()
      uniq = "#{System.unique_integer([:positive])}"
      dir = Path.join(tmp, "failed_test_#{uniq}")
      File.mkdir_p!(dir)
      File.cd!(dir)

      try do
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert catch_throw(Failed.run(nil)) == {:halted, 1}
          end)

        assert output =~ "No failed tests found"
      after
        File.cd!(original_dir)
        File.rm_rf!(dir)
      end
    end

    test "prints message when failed_tests.txt is empty" do
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", "")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Failed.run(nil)
        end)

      assert output =~ "No failed tests to run"
    end

    test "runs failed tests and reports success" do
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--warnings-as-errors")

      expect(CheckEscript.Port, :open, fn "mix", args ->
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
          Failed.run(nil)
        end)

      assert output =~ "Running 1 failed test(s)"
      assert output =~ "All previously failed tests now pass"
    end

    test "runs failed tests and reports failure" do
      stub_halt()
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", "test/bar_test.exs:20")
      Failed.save_test_args("--warnings-as-errors")

      expect(CheckEscript.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", "echo 'failure' && exit 1"]
        ])
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          catch_throw(Failed.run(nil))
        end)

      assert output =~ "Running 1 failed test(s)"
      assert output =~ "Some tests still failing"
    end

    test "passes repeat flag to test command" do
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--warnings-as-errors")

      expect(CheckEscript.Port, :open, fn "mix", args ->
        assert "--repeat-until-failure" in args
        assert "5" in args
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      ExUnit.CaptureIO.capture_io(fn ->
        Failed.run(5)
      end)
    end

    test "adds --export-coverage failed when saved args have --cover" do
      File.mkdir_p!(".check")
      File.write!(".check/failed_tests.txt", "test/foo_test.exs:10")
      Failed.save_test_args("--cover")

      expect(CheckEscript.Port, :open, fn "mix", args ->
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
        Failed.run(nil)
      end)
    end
  end
end
