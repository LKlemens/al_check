defmodule AlCheckTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

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

  test "--test-args stops at next check flag" do
    output =
      capture_io(fn ->
        CheckEscript.main(["--test-args", "--cover", "--only", "format", "mock"])
      end)

    assert output =~ "All checks passed"
  end
end
