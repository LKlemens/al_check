defmodule CheckEscript.CoverageTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Coverage

  describe "check/3" do
    test "parses total from table output" do
      output = """
      |    100.00% | SomeModule   |
      |     79.50% | Total        |
      """

      assert Coverage.check(output, "cover/", nil) == :ok
    end

    test "parses total from threshold failure output" do
      output = """
      Coverage:   16.92%
      Threshold:  90.00%
      """

      assert Coverage.check(output, "cover/", nil) == :ok
    end

    test "fails when below limit" do
      output = """
      |     40.00% | Total        |
      """

      assert Coverage.check(output, "cover/", 80) == :failed
    end

    test "passes when at limit" do
      output = """
      |     80.00% | Total        |
      """

      assert Coverage.check(output, "cover/", 80) == :ok
    end

    test "passes when above limit" do
      output = """
      |     95.50% | Total        |
      """

      assert Coverage.check(output, "cover/", 80) == :ok
    end

    test "returns ok when no percentage found" do
      assert Coverage.check("no coverage data", "cover/", nil) == :ok
    end
  end
end
