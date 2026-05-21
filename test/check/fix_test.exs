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

  describe "run/0 - format fix" do
    test "fixes format when marker exists" do
      File.mkdir_p!(".check")
      File.write!(".check/.format_failed", "")
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "mix", ["format"], opts ->
        assert opts[:stderr_to_stdout] == true
        {"", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Format check failed previously"
      assert output =~ "Format fixed successfully"
      refute File.exists?(".check/.format_failed")
    end

    test "reports format fix failure" do
      stub_halt()
      File.mkdir_p!(".check")
      File.write!(".check/.format_failed", "")
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "mix", ["format"], _opts ->
        {"format error", 1}
      end)

      output =
        capture_io(fn ->
          catch_throw(Fix.run())
        end)

      assert output =~ "Format fix failed"
    end

    test "skips format fix when no marker" do
      File.rm(".check/.format_failed")
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Format check passed"
      assert output =~ "No credo errors found"
    end
  end

  describe "run/0 - credo fix" do
    test "runs recode on files from credo output" do
      File.rm(".check/.format_failed")
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n")

      expect(System, :cmd, fn "mix", ["recode", "lib/foo.ex"], _opts ->
        {"fixed", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Found 1 file(s) with issues"
      assert output =~ "lib/foo.ex"
      assert output =~ "Auto-fixes applied successfully"
    end

    test "reports recode failure" do
      stub_halt()
      File.rm(".check/.format_failed")
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n")

      expect(System, :cmd, fn "mix", ["recode", "lib/foo.ex"], _opts ->
        {"recode error", 1}
      end)

      output =
        capture_io(fn ->
          catch_throw(Fix.run())
        end)

      assert output =~ "Recode exited with errors"
    end
  end
end
