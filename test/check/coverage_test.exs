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

  # Stubs for native merge tests - one fake coverdata file, no cache on disk.
  defp stub_coverdata(content \\ "fake") do
    stub(Path, :wildcard, fn "cover/*.coverdata" -> ["cover/fake.coverdata"] end)
    stub(File, :read!, fn "cover/fake.coverdata" -> content end)
    stub(File, :read, fn _path -> {:error, :enoent} end)
    stub(File, :write!, fn _path, _content -> :ok end)
    stub(File, :mkdir_p!, fn _path -> :ok end)
  end

  # In-memory filesystem backed by an Agent - captures writes and serves them
  # back on reads. Used for tests that verify caching behaviour.
  defp start_mem_fs do
    fs = start_supervised!({Agent, fn -> %{} end})

    stub(File, :write!, fn path, content ->
      Agent.update(fs, &Map.put(&1, path, content))
      :ok
    end)

    stub(File, :read, fn path ->
      case Agent.get(fs, &Map.get(&1, path)) do
        nil -> {:error, :enoent}
        content -> {:ok, content}
      end
    end)

    stub(File, :mkdir_p!, fn _path -> :ok end)
    fs
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
      stub_coverdata()

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
    end

    test "full: true prints the entire per-module table" do
      stub_coverdata()

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|  91.00% | MyApp.Foo |\n|  75.00% | Total        |")
      end)

      io =
        capture_io(fn ->
          send(
            self(),
            Coverage.merge(%{
              mod: :native,
              full: true,
              limit: nil,
              html: false,
              baseline_cmd: nil
            })
          )
        end)

      assert_received :ok
      assert io =~ "MyApp.Foo"
      assert io =~ "75.0%"
    end

    test "full: false omits the per-module table" do
      stub_coverdata()

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|  91.00% | MyApp.Foo |\n|  75.00% | Total        |")
      end)

      io =
        capture_io(fn ->
          send(
            self(),
            Coverage.merge(%{
              mod: :native,
              full: false,
              limit: nil,
              html: false,
              baseline_cmd: nil
            })
          )
        end)

      assert_received :ok
      refute io =~ "MyApp.Foo"
    end

    test "native path with html collects all output" do
      stub_coverdata()

      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     88.00% | Total        |\nGenerating HTML...")
      end)

      io =
        capture_io(fn ->
          send(self(), Coverage.merge(%{mod: :native, limit: nil, html: true, baseline_cmd: nil}))
        end)

      assert_received :ok
      assert io =~ "88.0%"
    end

    test "native path uses cache on second call" do
      stub(Path, :wildcard, fn "cover/*.coverdata" -> ["cover/fake.coverdata"] end)
      stub(File, :read!, fn "cover/fake.coverdata" -> "fake_data" end)
      start_mem_fs()

      # First call - cache miss, runs port
      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     92.00% | Total        |")
      end)

      capture_io(fn ->
        Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
      end)

      # Second call - cache hit, no port call expected (no expect = fails if called)
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
    end

    test "native path cache miss when coverdata changes" do
      counter = start_supervised!({Agent, fn -> 0 end}, id: :coverdata_counter)
      fs = start_supervised!({Agent, fn -> %{} end}, id: :coverage_fs)

      stub(Path, :wildcard, fn "cover/*.coverdata" -> ["cover/fake.coverdata"] end)

      stub(File, :read!, fn "cover/fake.coverdata" ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        if n == 0, do: "version1", else: "version2"
      end)

      stub(File, :write!, fn path, content ->
        Agent.update(fs, &Map.put(&1, path, content))
        :ok
      end)

      stub(File, :read, fn path ->
        case Agent.get(fs, &Map.get(&1, path)) do
          nil -> {:error, :enoent}
          content -> {:ok, content}
        end
      end)

      stub(File, :mkdir_p!, fn _path -> :ok end)

      # First call
      expect(Check.Port, :open, fn "mix", ["test.coverage"] ->
        echo_port("|     70.00% | Total        |")
      end)

      capture_io(fn ->
        Coverage.merge(%{mod: :native, limit: nil, html: false, baseline_cmd: nil})
      end)

      # Second call - coverdata changed, hash differs → cache miss → port runs again
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
    end

    test "native path fails when below limit" do
      stub_coverdata()

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
    end
  end

  describe "show_modified_files_coverage/0" do
    test "does nothing when cache file does not exist" do
      stub(File, :read, fn _path -> {:error, :enoent} end)
      io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
      assert io == ""
    end

    test "does nothing when base_branch cannot be resolved" do
      stub(File, :read, fn ".check/coverage_cache.txt" -> {:ok, "| SomeModule | 85.00% |"} end)
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
    test "copies module HTML to .check/cover_modified/ when cover file exists", %{
      tmp_dir: tmp_dir
    } do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("lib")
        File.mkdir_p!("cover")

        File.write!(".check/coverage_cache.txt", "| ModifiedModule | 74.00% |\n")
        File.write!("lib/modified_module.ex", "defmodule ModifiedModule do\nend\n")
        File.write!("cover/Elixir.ModifiedModule.html", "<html></html>")

        stub(Check.Config, :load, fn -> {:ok, %{}} end)
        stub(Check.Config, :base_branch, fn _config -> "main" end)

        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
            "--diff-filter=M" in args -> {"lib/modified_module.ex\n", 0}
            true -> {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.show_modified_files_coverage() end)

        assert File.exists?(".check/cover_modified/Elixir.ModifiedModule.html")
        assert io =~ "ModifiedModule"
        refute io =~ "\e]8;;"
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "matches module names exactly so a top-level module excludes its submodules",
         %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        File.mkdir_p!(".check")
        File.mkdir_p!("lib")

        coverage_output = """
        |     84.07% | Check          |
        |     86.23% | Check.Coverage |
        |     90.38% | Check.Config   |
        | Total          |  80.00% |
        """

        File.write!(".check/coverage_cache.txt", coverage_output)
        File.write!("lib/check.ex", "defmodule Check do\nend\n")

        stub(Check.Config, :load, fn -> {:ok, %{}} end)
        stub(Check.Config, :base_branch, fn _config -> "main" end)

        stub(System, :cmd, fn "git", args, _opts ->
          cond do
            args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
            "--diff-filter=M" in args -> {"lib/check.ex\n", 0}
            true -> {"", 0}
          end
        end)

        io = capture_io(fn -> Coverage.show_modified_files_coverage() end)
        assert io =~ "84.07%"
        refute io =~ "86.23%"
        refute io =~ "90.38%"
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

    @tag :tmp_dir
    test "copies HTML files for new/modified modules to .check/cover_modified/", %{
      tmp_dir: tmp_dir
    } do
      cover_dir = Path.join(tmp_dir, "cover")
      lib_file = Path.join(tmp_dir, "lib/my_mod.ex")

      File.mkdir_p!(Path.join(tmp_dir, ".check"))
      File.mkdir_p!(cover_dir)
      File.mkdir_p!(Path.dirname(lib_file))
      File.write!(Path.join(cover_dir, "Elixir.MyMod.html"), "<html>MyMod</html>")
      File.write!(Path.join(cover_dir, "cover.css"), "body {}")
      File.write!(lib_file, "defmodule MyMod do\nend\n")

      # Stub cwd so copy_modified_htmls resolves cover/ and .check/cover_modified/
      # relative to tmp_dir without changing the global OS process cwd.
      stub(File, :cwd!, fn -> tmp_dir end)

      stub(File, :read, fn
        ".check/coverage_cache.txt" -> {:ok, "| MyMod | 80.00% |\n"}
        _path -> {:error, :enoent}
      end)

      stub(Check.Config, :load, fn -> {:ok, %{}} end)
      stub(Check.Config, :base_branch, fn _config -> "main" end)

      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          "--diff-filter=A" in args -> {"", 0}
          "--diff-filter=M" in args -> {lib_file <> "\n", 0}
          true -> {"", 0}
        end
      end)

      capture_io(fn -> Coverage.show_modified_files_coverage() end)

      modified_dir = Path.join(tmp_dir, ".check/cover_modified")
      assert File.exists?(Path.join(modified_dir, "Elixir.MyMod.html"))
      assert File.exists?(Path.join(modified_dir, "cover.css"))
      assert File.read!(Path.join(modified_dir, "Elixir.MyMod.html")) == "<html>MyMod</html>"
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
