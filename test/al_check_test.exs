defmodule AlCheckTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  setup :verify_on_exit!

  test "version is set" do
    assert is_binary(Mix.Project.config()[:version])
  end

  test "--version prints version" do
    output = capture_io(fn -> CheckEscript.main(["--version"]) end)
    assert output =~ "check #{Mix.Project.config()[:version]}"
  end

  test "-v prints version" do
    output = capture_io(fn -> CheckEscript.main(["-v"]) end)
    assert output =~ "check"
  end

  test "--help prints usage" do
    output = capture_io(fn -> CheckEscript.main(["--help"]) end)
    assert output =~ "Usage"
    assert output =~ "check --fast"
  end

  test "-h prints usage" do
    output = capture_io(fn -> CheckEscript.main(["-h"]) end)
    assert output =~ "Usage"
  end

  test "--init creates config" do
    # Already tested in config_test, just verify main routes correctly
    output = capture_io(fn -> CheckEscript.main(["--init"]) end)
    assert output =~ "already exists" or output =~ "Created"
  end

  test "--only format mock runs single check" do
    output = capture_io(fn -> CheckEscript.main(["--only", "format", "mock"]) end)
    assert output =~ "All checks passed"
  end

  test "--dir with multiple dirs" do
    output =
      capture_io(fn ->
        CheckEscript.main(["--only", "format", "--dir", "test/a,test/b", "mock"])
      end)

    assert output =~ "All checks passed"
  end

  test "--test-args accepts quoted string" do
    output =
      capture_io(fn ->
        CheckEscript.main(["--test-args", "--exclude slow --cover", "--only", "format", "mock"])
      end)

    assert output =~ "All checks passed"
  end

  describe "invalid flags" do
    test "rejects unknown flag with suggestion" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(CheckEscript.main(["--repat"]))
        end)

      assert output =~ "Unknown flag: --repat"
      assert output =~ "Did you mean --repeat?"
    end

    test "rejects unknown flag without suggestion when no close match" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(CheckEscript.main(["--bogus"]))
        end)

      assert output =~ "Unknown flag: --bogus"
      refute output =~ "Did you mean"
    end

    test "suggests --fast for --fastt" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(CheckEscript.main(["--fastt"]))
        end)

      assert output =~ "Did you mean --fast?"
    end

    test "suggests --coverage for --coverge" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(CheckEscript.main(["--coverge"]))
        end)

      assert output =~ "Did you mean --coverage?"
    end
  end
end
