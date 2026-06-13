defmodule AlCheckTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  setup :verify_on_exit!

  test "version is set" do
    assert is_binary(Mix.Project.config()[:version])
  end

  test "--version prints version" do
    output = capture_io(fn -> Check.main(["--version"]) end)
    assert output =~ "check #{Mix.Project.config()[:version]}"
  end

  test "-v prints version" do
    output = capture_io(fn -> Check.main(["-v"]) end)
    assert output =~ "check"
  end

  test "--help prints usage" do
    output = capture_io(fn -> Check.main(["--help"]) end)
    assert output =~ "Usage"
    assert output =~ "check --fast"
  end

  test "-h prints usage" do
    output = capture_io(fn -> Check.main(["-h"]) end)
    assert output =~ "Usage"
  end

  test "--init creates config" do
    # Already tested in config_test, just verify main routes correctly
    output = capture_io(fn -> Check.main(["--init"]) end)
    assert output =~ "already exists" or output =~ "Created"
  end

  test "--only format mock runs single check" do
    output = capture_io(fn -> Check.main(["--only", "format", "mock"]) end)
    assert output =~ "All checks passed"
  end

  test "--dir with multiple dirs" do
    output =
      capture_io(fn ->
        Check.main(["--only", "format", "--dir", "test/a,test/b", "mock"])
      end)

    assert output =~ "All checks passed"
  end

  test "--test-args accepts quoted string" do
    output =
      capture_io(fn ->
        Check.main(["--test-args", "--exclude slow --cover", "--only", "format", "mock"])
      end)

    assert output =~ "All checks passed"
  end

  describe "invalid flags" do
    test "rejects unknown flag with suggestion" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--repat"]))
        end)

      assert output =~ "Unknown flag: --repat"
      assert output =~ "Did you mean --repeat?"
    end

    test "rejects unknown flag without suggestion when no close match" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--bogus"]))
        end)

      assert output =~ "Unknown flag: --bogus"
      refute output =~ "Did you mean"
    end

    test "suggests --fast for --fastt" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--fastt"]))
        end)

      assert output =~ "Did you mean --fast?"
    end

    test "suggests --coverage for --coverge" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--coverge"]))
        end)

      assert output =~ "Did you mean --coverage?"
    end
  end

  describe "version mismatch warning" do
    @tag :tmp_dir
    test "warns when dep version is newer", %{tmp_dir: tmp_dir} do
      dep_dir = Path.join([tmp_dir, "deps", "al_check"])
      File.mkdir_p!(dep_dir)
      File.write!(Path.join(dep_dir, "mix.exs"), ~s|@version "99.0.0"|)

      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        output = capture_io(fn -> Check.main(["--version"]) end)

        assert output =~ "outdated"
        assert output =~ "99.0.0"
        assert output =~ "mix check.update"
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "no warning when dep version is same or older", %{tmp_dir: tmp_dir} do
      dep_dir = Path.join([tmp_dir, "deps", "al_check"])
      File.mkdir_p!(dep_dir)
      File.write!(Path.join(dep_dir, "mix.exs"), ~s|@version "0.0.1"|)

      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        output = capture_io(fn -> Check.main(["--version"]) end)
        refute output =~ "outdated"
      after
        File.cd!(original_dir)
      end
    end

    test "no warning when no deps/al_check exists" do
      output = capture_io(fn -> Check.main(["--version"]) end)
      refute output =~ "outdated"
    end
  end

  describe "--no-coverage" do
    test "runs tests without coverage" do
      output =
        capture_io(fn ->
          Check.main(["--only", "test", "--no-coverage", "--partitions", "1", "mock"])
        end)

      assert output =~ "All checks passed"
      saved = File.read!(".check/test_args.txt")
      refute saved =~ "--cover"
    end

    test "--no-coverage overrides config coverage" do
      output =
        capture_io(fn ->
          Check.main(["--only", "test", "--no-coverage", "--partitions", "1", "mock"])
        end)

      assert output =~ "All checks passed"
      refute output =~ "Merging coverage"
    end
  end

  describe "partition commands" do
    test "--setup-db runs db setup for partitions" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 mix ecto.setup"],
                              _opts ->
        {"", 0}
      end)

      output =
        capture_io(fn ->
          Check.main(["--setup-db", "--partitions", "1"])
        end)

      assert output =~ "mix ecto.setup"
      assert output =~ "All 1 partition(s) done"
    end

    test "--drop-db runs db drop for partitions" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 mix ecto.drop"],
                              _opts ->
        {"", 0}
      end)

      output =
        capture_io(fn ->
          Check.main(["--drop-db", "--partitions", "1"])
        end)

      assert output =~ "mix ecto.drop"
      assert output =~ "All 1 partition(s) done"
    end

    test "--for-partitions runs custom command" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      expect(System, :cmd, fn "sh",
                              ["-c", "MIX_ENV=test MIX_TEST_PARTITION=1 echo hello"],
                              _opts ->
        {"", 0}
      end)

      output =
        capture_io(fn ->
          Check.main(["--for-partitions", "echo hello", "--partitions", "1"])
        end)

      assert output =~ "echo hello"
      assert output =~ "All 1 partition(s) done"
    end
  end

  describe "validation" do
    test "--partitions 0 is rejected" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--partitions", "0", "--only", "format", "mock"]))
        end)

      assert output =~ "--partitions must be greater than 0"
    end

    test "--partitions negative is rejected" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--partitions", "-1", "--only", "format", "mock"]))
        end)

      assert output =~ "--partitions must be greater than 0"
    end

    test "--repeat 0 is rejected" do
      stub(System, :halt, fn code -> throw({:halted, code}) end)

      output =
        capture_io(:stderr, fn ->
          catch_throw(Check.main(["--repeat", "0", "--only", "format", "mock"]))
        end)

      assert output =~ "--repeat must be greater than 0"
    end

    test "valid --partitions and --repeat are accepted" do
      output =
        capture_io(fn ->
          Check.main(["--partitions", "1", "--only", "format", "mock"])
        end)

      assert output =~ "All checks passed"
    end
  end
end
