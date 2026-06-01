defmodule Check.FixTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Check.Fix

  setup :verify_on_exit!

  defp stub_halt do
    stub(System, :halt, fn code -> throw({:halted, code}) end)
  end

  describe "extract_file_paths/1" do
    test "extracts file paths from credo output" do
      output = "  ┃   lib/foo/bar.ex:123:5\n  ┃   lib/baz.ex:45\n"

      files = Fix.extract_file_paths(output)
      assert "lib/foo/bar.ex" in files
      assert "lib/baz.ex" in files
    end

    test "handles .exs files" do
      output = "  ┃   test/some_test.exs:10:3\n"
      assert Fix.extract_file_paths(output) == ["test/some_test.exs"]
    end

    test "returns empty for no matches" do
      assert Fix.extract_file_paths("no files here") == []
    end
  end

  describe "run/0 - simple commands" do
    test "runs default fix commands" do
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Running: mix format"
      assert output =~ "No files found"
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

  describe "run/0 - files from txt" do
    test "runs recode on files from credo txt" do
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

    test "skips when txt file does not exist" do
      File.rm(".check/credo.txt")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "No files found"
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
      assert output =~ "lib/foo.ex"
      assert output =~ "lib/bar.ex"
    end

    test "deduplicates files" do
      File.mkdir_p!(".check")
      File.write!(".check/credo.txt", "  ┃   lib/foo.ex:10:5\n  ┃   lib/foo.ex:20:3\n")
      File.rm(".check/credo_strict.txt")

      expect(System, :cmd, fn "sh", ["-c", "mix format"], _opts -> {"", 0} end)

      expect(System, :cmd, fn "mix", ["recode", "lib/foo.ex"], _opts ->
        {"fixed", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "1 file(s)"
    end
  end

  describe "run/0 - files from glob" do
    @tag :tmp_dir
    test "reads from multiple matched files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "credo.txt"), "  ┃   lib/foo.ex:10:5\n")
      File.write!(Path.join(tmp_dir, "credo_strict.txt"), "  ┃   lib/bar.ex:20:3\n")

      config = %{"fix" => [%{"run" => "echo fix", "files" => "#{tmp_dir}/credo*.txt"}]}
      expect(Check.Config, :load, fn -> {:ok, config} end)

      expect(System, :cmd, fn "echo", ["fix", "lib/bar.ex", "lib/foo.ex"], _opts ->
        {"ok", 0}
      end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "2 file(s)"
      assert output =~ "All fixes applied successfully"
    end

    @tag :tmp_dir
    test "skips when glob matches nothing", %{tmp_dir: tmp_dir} do
      config = %{"fix" => [%{"run" => "echo fix", "files" => "#{tmp_dir}/*.nothing"}]}
      expect(Check.Config, :load, fn -> {:ok, config} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "No files found"
    end
  end

  describe "run/0 - custom config" do
    test "runs custom fix commands" do
      config = %{"fix" => [%{"run" => "echo custom_fix"}]}

      expect(Check.Config, :load, fn -> {:ok, config} end)
      expect(System, :cmd, fn "sh", ["-c", "echo custom_fix"], _opts -> {"done", 0} end)

      output = capture_io(fn -> Fix.run() end)

      assert output =~ "Running: echo custom_fix"
      assert output =~ "All fixes applied successfully"
    end
  end
end
