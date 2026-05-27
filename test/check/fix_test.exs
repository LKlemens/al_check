defmodule CheckEscript.FixTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias CheckEscript.Fix

  setup :verify_on_exit!

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "extract_files_from_credo_output/1" do
    test "extracts file paths from credo output" do
      output = "  ┃   lib/foo/bar.ex:123:5\n  ┃   lib/baz.ex:45\n"

      files = Fix.extract_files_from_credo_output(output)
      assert "lib/foo/bar.ex" in files
      assert "lib/baz.ex" in files
    end

    test "handles .exs files" do
      output = "  ┃   test/some_test.exs:10:3\n"
      assert Fix.extract_files_from_credo_output(output) == ["test/some_test.exs"]
    end

    test "returns empty for no matches" do
      assert Fix.extract_files_from_credo_output("no files here") == []
    end
  end

  describe "run/0 - simple commands" do
    test "runs default fix commands" do
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Running: mix format"
      assert output =~ "No credo files to fix"
      assert output =~ "All fixes applied successfully"
    end

    test "halts on command failure" do
      stub_halt()

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"error", 1} end)

      output =
        capture_io(fn ->
          catch_throw(Fix.run())
        end)

      assert output =~ "mix format failed"
    end
  end

  describe "run/0 - on_credo_files" do
    test "runs recode on credo-failing files" do
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n  ┃   lib/bar.ex:20:3\n")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      expect(System, :cmd, fn "mix", ["recode", "lib/bar.ex", "lib/foo.ex"], _opts ->
        {"fixed", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Running: mix recode (2 file(s))"
      assert output =~ "lib/foo.ex"
      assert output =~ "lib/bar.ex"
      assert output =~ "All fixes applied successfully"
    end

    test "skips recode when no credo files" do
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "No credo files to fix"
      assert output =~ "All fixes applied successfully"
    end

    test "combines files from credo and credo_strict" do
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n")
      File.write!(".check/credo_strict.txt", "  ┃   lib/bar.ex:20:3\n")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      expect(System, :cmd, fn "mix", ["recode", "lib/bar.ex", "lib/foo.ex"], _opts ->
        {"fixed", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "2 file(s)"
    end

    test "deduplicates files across credo outputs" do
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n")
      File.write!(".check/credo_strict.txt", "  ┃   lib/foo.ex:20:3\n")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      expect(System, :cmd, fn "mix", ["recode", "lib/foo.ex"], _opts ->
        {"fixed", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "1 file(s)"
    end
  end

  describe "run/0 - custom config" do
    test "runs custom fix commands" do
      config = %{"fix" => [%{"run" => "echo custom_fix"}]}

      expect(CheckEscript.Config, :load, fn -> {:ok, config} end)
      expect(System, :cmd, fn "sh", ["-c", "echo custom_fix"], _opts -> {"done", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Running: echo custom_fix"
      assert output =~ "All fixes applied successfully"
    end
  end
end
