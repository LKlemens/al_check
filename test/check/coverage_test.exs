defmodule Check.CoverageTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Check.Coverage

  setup :verify_on_exit!

  defp echo_port(text) do
    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-c", "echo '#{text}'"]
    ])
  end

  describe "check/3" do
    test "parses total from table output" do
      output = "|    100.00% | SomeModule   |\n|     79.50% | Total        |"

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
      assert io =~ "79.5%"
    end

    test "parses total from threshold failure output" do
      output = "Coverage:   16.92%\nThreshold:  90.00%"
      capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
    end

    test "fails when below limit" do
      output = "|     40.00% | Total        |"

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", 80)) end)
      assert_received :failed
      assert io =~ "40.0%"
      assert io =~ "limit: 80%"
    end

    test "passes when at limit" do
      output = "|     80.00% | Total        |"
      capture_io(fn -> send(self(), Coverage.check(output, "cover/", 80)) end)
      assert_received :ok
    end

    test "passes when above limit" do
      output = "|     95.50% | Total        |"
      capture_io(fn -> send(self(), Coverage.check(output, "cover/", 80)) end)
      assert_received :ok
    end

    test "returns ok when no percentage found" do
      io = capture_io(fn -> send(self(), Coverage.check("no data", "cover/", nil)) end)
      assert_received :ok
      assert io =~ "Could not parse coverage"
    end

    test "passes when limit is nil" do
      output = "|     10.00% | Total        |"
      capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
    end

    test "shows green for high coverage" do
      output = "|     90.00% | Total        |"
      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
      assert io =~ "90.0%"
    end

    test "shows yellow for medium coverage" do
      output = "|     60.00% | Total        |"
      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
      assert io =~ "60.0%"
    end

    test "shows red for low coverage" do
      output = "|     20.00% | Total        |"
      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", nil)) end)
      assert_received :ok
      assert io =~ "20.0%"
    end
  end

  describe "check/3 with baseline" do
    test "shows positive delta when coverage increased" do
      output = "|     85.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: "echo 80.0"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "+5.0%"
      assert io =~ "baseline"
    end

    test "shows negative delta when coverage decreased" do
      output = "|     75.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: "echo 80.0"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "-5.0%"
    end

    test "shows same when equal" do
      output = "|     80.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: "echo 80.0"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "same as baseline"
    end

    test "warns when baseline command fails" do
      output = "|     80.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: "exit 1"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "Baseline command failed"
    end

    test "warns when baseline output is not a number" do
      output = "|     80.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: "echo 'not a number'"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "Could not parse baseline"
    end

    test "skips baseline when baseline_cmd is nil" do
      output = "|     80.00% | Total        |"
      coverage = %{limit: nil, baseline_cmd: nil}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      refute io =~ "baseline"
    end

    test "checks both limit and baseline" do
      output = "|     85.00% | Total        |"
      coverage = %{limit: 80, baseline_cmd: "echo 82.0"}

      io = capture_io(fn -> send(self(), Coverage.check(output, "cover/", coverage)) end)
      assert_received :ok
      assert io =~ "85.0%"
      assert io =~ "+3.0%"
    end
  end

  describe "merge/1" do
    test "returns ok for disabled coverage" do
      assert Coverage.merge(%{mod: false}) == :ok
    end

    test "coveralls path calls System.cmd and checks output" do
      expect(System, :cmd, fn "mix", ["coveralls", "--import-cover", "cover/"], _opts ->
        {"|     85.00% | Total        |", 0}
      end)

      io =
        capture_io(fn ->
          send(self(), Coverage.merge(%{mod: :coveralls, limit: 80, baseline_cmd: nil}))
        end)

      assert_received :ok
      assert io =~ "85.0%"
    end

    test "coveralls path fails when below limit" do
      expect(System, :cmd, fn "mix", ["coveralls", "--import-cover", "cover/"], _opts ->
        {"|     30.00% | Total        |", 0}
      end)

      io =
        capture_io(fn ->
          send(self(), Coverage.merge(%{mod: :coveralls, limit: 50, baseline_cmd: nil}))
        end)

      assert_received :failed
      assert io =~ "30.0%"
    end

    test "native path without html kills after Total line" do
      # Create a fake coverdata file so hash works
      File.mkdir_p!("cover")
      File.write!("cover/test.coverdata", "fake")
      # Clear cache
      File.rm(".check/coverage_cache.hash")
      File.rm(".check/coverage_cache.txt")

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     75.00% | Total        |")
      end)

      io =
        capture_io(fn ->
          send(
            self(),
            Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
          )
        end)

      assert_received :ok
      assert io =~ "75.0%"
      assert io =~ "Merging coverage data"
    after
      File.rm_rf!("cover/test.coverdata")
    end

    test "native path with html collects all output" do
      File.mkdir_p!("cover")
      File.write!("cover/test.coverdata", "fake")
      File.rm(".check/coverage_cache.hash")
      File.rm(".check/coverage_cache.txt")

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     88.00% | Total        |\nGenerating HTML...")
      end)

      io =
        capture_io(fn ->
          send(self(), Coverage.merge(%{mod: :native, limit: nil, html: true, baseline_cmd: nil}))
        end)

      assert_received :ok
      assert io =~ "88.0%"
    after
      File.rm_rf!("cover/test.coverdata")
    end

    test "native path uses cache on second call" do
      File.mkdir_p!("cover")
      File.write!("cover/test.coverdata", "fake_data")
      File.rm(".check/coverage_cache.hash")
      File.rm(".check/coverage_cache.txt")

      # First call — cache miss, runs port
      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     92.00% | Total        |")
      end)

      capture_io(fn ->
        Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
      end)

      # Second call — cache hit, no port call expected (no expect = fails if called)
      io =
        capture_io(fn ->
          send(
            self(),
            Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
          )
        end)

      assert_received :ok
      assert io =~ "(cached)"
      assert io =~ "92.0%"
    after
      File.rm_rf!("cover/test.coverdata")
    end

    test "native path cache miss when coverdata changes" do
      File.mkdir_p!("cover")
      File.write!("cover/test.coverdata", "version1")
      File.rm(".check/coverage_cache.hash")
      File.rm(".check/coverage_cache.txt")

      # First call
      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     70.00% | Total        |")
      end)

      capture_io(fn ->
        Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
      end)

      # Change coverdata
      File.write!("cover/test.coverdata", "version2")

      # Second call — cache miss, new port call
      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     80.00% | Total        |")
      end)

      io =
        capture_io(fn ->
          send(
            self(),
            Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
          )
        end)

      assert_received :ok
      refute io =~ "(cached)"
      assert io =~ "80.0%"
    after
      File.rm_rf!("cover/test.coverdata")
    end

    test "native path fails when below limit" do
      File.mkdir_p!("cover")
      File.write!("cover/test.coverdata", "fake")
      File.rm(".check/coverage_cache.hash")
      File.rm(".check/coverage_cache.txt")

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     50.00% | Total        |")
      end)

      io =
        capture_io(fn ->
          send(self(), Coverage.merge(%{mod: :native, limit: 80, html: false, baseline_cmd: nil}))
        end)

      assert_received :failed
      assert io =~ "50.0%"
      assert io =~ "limit: 80%"
    after
      File.rm_rf!("cover/test.coverdata")
    end
  end

  describe "show_modified_files_coverage/0" do
    test "does nothing when cache file does not exist" do
      File.rm(".check/coverage_cache.txt")
      io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
      assert io == ""
    end

    test "does nothing when base_branch cannot be resolved" do
      File.mkdir_p!(".check")
      File.write!(".check/coverage_cache.txt", "| SomeModule | 85.00% |")
      stub(Check.Config, :load, fn -> {:ok, %{}} end)
      stub(Check.Config, :base_branch, fn _config -> nil end)
      io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
      assert io == ""
    end

    @tag :tmp_dir
    test "shows coverage for new and modified files separately", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("lib")

        coverage_output = """
        | NewModule      |  91.00% |
        | ModifiedModule |  74.00% |
        | UnrelatedModule|  60.00% |
        | Total          |  80.00% |
        """

        File.write!(".check/coverage_cache.txt", coverage_output)
        File.write!("lib/new_module.ex", "defmodule NewModule do\nend\n")
        File.write!("lib/modified_module.ex", "defmodule ModifiedModule do\nend\n")

        stub(Check.Config, :load, fn -> {:ok, %{}} end)
        stub(Check.Config, :base_branch, fn _config -> "main" end)

        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
            "--diff-filter=A" in args -> {"lib/new_module.ex\n", 0}
            "--diff-filter=M" in args -> {"lib/modified_module.ex\n", 0}
            true -> {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
        assert io =~ "Coverage of new files:"
        assert io =~ "NewModule"
        assert io =~ "Coverage of modified files:"
        assert io =~ "ModifiedModule"
        refute io =~ "UnrelatedModule"
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "on the base branch, diffs against HEAD~1 instead of an empty range", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("lib")

        File.write!(".check/coverage_cache.txt", "| ModifiedModule | 74.00% |\n")
        File.write!("lib/modified_module.ex", "defmodule ModifiedModule do\nend\n")

        stub(Check.Config, :load, fn -> {:ok, %{}} end)
        stub(Check.Config, :base_branch, fn _config -> "main" end)

        # current branch == base branch ("main"), and a parent commit exists,
        # so the diff must target HEAD~1 — never the empty "main...HEAD" range.
        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] ->
              {"main\n", 0}

            args == ["rev-parse", "--verify", "--quiet", "HEAD~1"] ->
              {"abc123\n", 0}

            "--diff-filter=M" in args ->
              assert "HEAD~1" in args
              refute "main...HEAD" in args
              {"lib/modified_module.ex\n", 0}

            true ->
              {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
        assert io =~ "ModifiedModule"
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "shows average percentage for each group", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("lib")

        coverage_output = """
        | ModA | 80.00% |
        | ModB | 60.00% |
        """

        File.write!(".check/coverage_cache.txt", coverage_output)
        File.write!("lib/mod_a.ex", "defmodule ModA do\nend\n")
        File.write!("lib/mod_b.ex", "defmodule ModB do\nend\n")

        stub(Check.Config, :load, fn -> {:ok, %{}} end)
        stub(Check.Config, :base_branch, fn _config -> "main" end)

        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
            "--diff-filter=A" in args -> {"", 0}
            "--diff-filter=M" in args -> {"lib/mod_a.ex\nlib/mod_b.ex\n", 0}
            true -> {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
        assert io =~ "Average: 70.0%"
      after
        File.cd!(original_dir)
      end
    end
  end

  describe "maybe_merge_and_show_modified/0" do
    test "does nothing when coverage mod is false" do
      stub(Check.Config, :load, fn ->
        {:ok, %{"coverage" => %{"mod" => "disabled"}}}
      end)

      stub(Check.Config, :parse_coverage, fn _c -> %{mod: false} end)
      io = capture_io(fn -> Coverage.maybe_merge_and_show_modified() end)
      assert io == ""
    end

    test "does nothing when config load fails" do
      stub(Check.Config, :load, fn -> :error end)
      io = capture_io(fn -> Coverage.maybe_merge_and_show_modified() end)
      assert io == ""
    end

    @tag :tmp_dir
    test "uses cache and shows modified coverage for native mod", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("cover")
        File.mkdir_p!("lib")

        coverdata_content = "fake_coverdata_for_modified"
        File.write!("cover/modified.coverdata", coverdata_content)

        hash =
          :crypto.hash(:md5, coverdata_content) |> Base.encode16(case: :lower)

        coverage_output = "| MyMod | 88.00% |\n"
        File.write!(".check/coverage_cache.hash", hash)
        File.write!(".check/coverage_cache.txt", coverage_output)
        File.write!("lib/my_mod.ex", "defmodule MyMod do\nend\n")

        stub(Check.Config, :load, fn ->
          {:ok, %{"coverage" => %{"mod" => "native"}}}
        end)

        stub(Check.Config, :parse_coverage, fn _c ->
          %{mod: :native, limit: nil, html: false, baseline_cmd: nil}
        end)

        stub(Check.Config, :base_branch, fn _config -> "main" end)

        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
            "--diff-filter=A" in args -> {"lib/my_mod.ex\n", 0}
            "--diff-filter=M" in args -> {"", 0}
            true -> {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.maybe_merge_and_show_modified() end)
        assert io =~ "MyMod"
      after
        File.cd!(original_dir)
      end
    end
  end
end
