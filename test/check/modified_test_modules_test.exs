defmodule Check.ModifiedTestModulesTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Check.ModifiedTestModules

  setup :verify_on_exit!

  describe "run/1" do
    test "returns ok when no modified files" do
      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          match?(["rev-parse" | _], args) -> {"", 0}
          true -> {"", 0}
        end
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTestModules.run())
        end)

      assert_received {0, _}
      assert output =~ "no modified test modules found"
    end

    @tag :tmp_dir
    test "runs test on modified files", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "my_test.exs")
      File.write!(file, "defmodule MyTest do\nend\n")

      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          match?(["rev-parse" | _], args) -> {"", 0}
          match?(["diff", "--name-only" | _], args) -> {file <> "\n", 0}
          true -> {"", 0}
        end
      end)

      expect(Check.Port, :open, fn "mix", ["test" | args] ->
        assert file in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTestModules.run())
        end)

      assert_received {0, _}
      assert output =~ "Test command"
      assert output =~ "1 modules"
    end

    @tag :tmp_dir
    test "on the base branch, diffs against the latest commit not an empty range", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "my_test.exs")
      File.write!(file, "defmodule MyTest do\nend\n")

      test_pid = self()

      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] ->
            {"main\n", 0}

          match?(["rev-parse", "--verify", "--quiet" | _], args) ->
            {"abc123\n", 0}

          match?(["diff", "--name-only" | _], args) ->
            send(test_pid, {:diff_args, args})
            {file <> "\n", 0}

          true ->
            {"", 0}
        end
      end)

      stub(Check.Port, :open, fn "mix", _args ->
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      capture_io(fn -> send(self(), ModifiedTestModules.run()) end)

      assert_received {:diff_args, diff_args}
      assert "HEAD~1...HEAD" in diff_args
      refute "main...HEAD" in diff_args
    end

    test "passes repeat and test_args" do
      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          match?(["rev-parse" | _], args) -> {"", 0}
          match?(["diff", "--name-only" | _], args) -> {"test/foo_test.exs\n", 0}
          true -> {"", 0}
        end
      end)

      # File must exist for filter
      File.mkdir_p!("test")
      File.write!("test/foo_test.exs", "defmodule FooTest do\nend\n")

      expect(Check.Port, :open, fn "mix", args ->
        assert "--warnings-as-errors" in args
        assert "--repeat-until-failure" in args
        assert "5" in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["ok"]
        ])
      end)

      capture_io(fn ->
        ModifiedTestModules.run(%{test_args: "--warnings-as-errors", repeat: 5})
      end)
    end

    test "handles git failure gracefully" do
      stub(System, :cmd, fn "git", args, _opts ->
        cond do
          args == ["rev-parse", "--abbrev-ref", "HEAD"] -> {"feature\n", 0}
          match?(["rev-parse" | _], args) -> {"", 0}
          match?(["diff", "--name-only" | _], args) -> {"fatal: error", 128}
          true -> {"", 0}
        end
      end)

      capture_io(fn ->
        send(self(), ModifiedTestModules.run())
      end)

      assert_received {1, msg}
      assert msg =~ "git diff failed"
    end
  end
end
