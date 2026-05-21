defmodule CheckEscript.FailedTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Failed

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
      output = """
      ..........

      Finished in 0.1 seconds
      10 tests, 0 failures
      """

      assert Failed.extract_from_output(output) == []
    end
  end

  describe "extract_warning_locations/1" do
    test "extracts warning locations" do
      output = """
      └─ test/my_app/some_test.exs:16:5: MyApp.SomeTest."test name"/1
      """

      assert Failed.extract_warning_locations(output) == ["test/my_app/some_test.exs:16"]
    end

    test "returns empty when no warnings" do
      assert Failed.extract_warning_locations("no warnings here") == []
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
      output = """
      10 tests, 0 failures
      Expected minimum coverage of 90%, got 50%
      """

      assert Failed.coverage_threshold_failure?(output)
    end

    test "false when tests actually failed" do
      output = """
      10 tests, 3 failures
      Expected minimum coverage of 90%, got 50%
      """

      refute Failed.coverage_threshold_failure?(output)
    end

    test "false when no coverage message" do
      output = "10 tests, 0 failures"
      refute Failed.coverage_threshold_failure?(output)
    end
  end
end
