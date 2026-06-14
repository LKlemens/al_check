defmodule Check.SummaryTest do
  use ExUnit.Case, async: true

  alias Check.Summary

  describe "extract_test_summary/1" do
    test "extracts summary line from test output" do
      output = "...\n3 tests, 1 failure\nsome other line"
      assert Summary.extract_test_summary(output) == "3 tests, 1 failure"
    end

    test "returns fallback when no summary found" do
      assert Summary.extract_test_summary("no match here") ==
               "See .check/check_tests.txt for details"
    end

    test "includes excluded count" do
      output = "5 tests, 0 failures, 2 excluded"
      assert Summary.extract_test_summary(output) == "5 tests, 0 failures, 2 excluded"
    end
  end

  describe "format_duration/1" do
    test "zero seconds" do
      assert Summary.format_duration(0) == "0s"
    end

    test "under a minute" do
      assert Summary.format_duration(45) == "45s"
    end

    test "exact minute boundary" do
      assert Summary.format_duration(60) == "1m 0s"
    end

    test "minutes and seconds" do
      assert Summary.format_duration(75) == "1m 15s"
    end

    test "hours minutes seconds" do
      assert Summary.format_duration(3600) == "1h 0m 0s"
      assert Summary.format_duration(3661) == "1h 1m 1s"
    end
  end

  describe "colorize_line/1" do
    test "colorizes error lines red" do
      assert [_] = Summary.colorize_line("** (RuntimeError) boom")
    end

    test "returns plain string for normal lines" do
      assert Summary.colorize_line("normal output") == "normal output"
    end
  end
end
