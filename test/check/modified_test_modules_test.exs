defmodule Check.ModifiedTestModulesTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Check.ModifiedTestModules

  setup :verify_on_exit!

  describe "run/1" do
    test "returns ok when no modified files" do
      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {"", 0} end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTestModules.run())
        end)

      assert_received {0, ""}
      assert output =~ "No modified test files"
    end

    @tag :tmp_dir
    test "runs test on modified files", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "my_test.exs")
      File.write!(file, "defmodule MyTest do\nend\n")

      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)

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

      assert_received {0, ""}
      assert output =~ "Test command"
      assert output =~ "1 modules"
    end

    test "passes repeat and test_args" do
      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)

      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts ->
        {"test/foo_test.exs\n", 0}
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
      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)

      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts ->
        {"fatal: error", 128}
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTestModules.run())
        end)

      assert_received {0, ""}
      assert output =~ "git diff failed"
    end
  end
end
