defmodule CheckEscript.ModifiedTestsTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias CheckEscript.ModifiedTests

  setup :verify_on_exit!

  describe "find_enclosing_test/2" do
    test "finds test line above changed line" do
      lines = [
        "defmodule MyTest do",
        "  use ExUnit.Case",
        "",
        "  test \"something\" do",
        "    assert 1 + 1 == 2",
        "    assert true",
        "  end",
        "end"
      ]

      assert ModifiedTests.find_enclosing_test(lines, 5) == 4
      assert ModifiedTests.find_enclosing_test(lines, 6) == 4
    end

    test "finds test with double quotes" do
      lines = [
        "defmodule MyTest do",
        "  test \"something\" do",
        "    assert true",
        "  end"
      ]

      assert ModifiedTests.find_enclosing_test(lines, 3) == 2
    end

    test "returns nil when no test above" do
      lines = [
        "defmodule MyTest do",
        "  use ExUnit.Case",
        "  @tag :skip"
      ]

      assert ModifiedTests.find_enclosing_test(lines, 3) == nil
    end

    test "finds nearest test when multiple exist" do
      lines = [
        "  test \"first\" do",
        "    assert true",
        "  end",
        "",
        "  test \"second\" do",
        "    assert false",
        "  end"
      ]

      assert ModifiedTests.find_enclosing_test(lines, 6) == 5
      assert ModifiedTests.find_enclosing_test(lines, 2) == 1
    end
  end

  describe "setup_or_describe_changed?/2" do
    @tag :tmp_dir
    test "detects setup change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        setup do
          {:ok, conn: build_conn()}
        end

        test "something" do
          assert true
        end
      end
      """)

      assert ModifiedTests.setup_or_describe_changed?(file, [2])
    end

    @tag :tmp_dir
    test "detects setup_all change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        setup_all do
          {:ok, data: seed()}
        end
      end
      """)

      assert ModifiedTests.setup_or_describe_changed?(file, [2])
    end

    @tag :tmp_dir
    test "detects describe change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        describe "feature" do
          test "works" do
            assert true
          end
        end
      end
      """)

      assert ModifiedTests.setup_or_describe_changed?(file, [2])
    end

    @tag :tmp_dir
    test "returns false for test-only change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        setup do
          {:ok, conn: build_conn()}
        end

        test "something" do
          assert true
        end
      end
      """)

      refute ModifiedTests.setup_or_describe_changed?(file, [7])
    end
  end

  describe "find_test_lines/2" do
    @tag :tmp_dir
    test "finds specific test lines for changed lines", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        test "first" do
          assert 1 == 1
        end

        test "second" do
          assert 2 == 2
        end
      end
      """)

      result = capture_io(fn -> send(self(), ModifiedTests.find_test_lines(file, [3])) end)
      assert_received [target]
      assert target =~ ":2"
      assert result =~ ":2"
    end

    @tag :tmp_dir
    test "returns whole file for module-level change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        use ExUnit.Case
        @moduletag :integration

        test "something" do
          assert true
        end
      end
      """)

      result = capture_io(fn -> send(self(), ModifiedTests.find_test_lines(file, [3])) end)
      assert_received [^file]
      assert result =~ "module-level change"
    end

    @tag :tmp_dir
    test "deduplicates when multiple lines in same test", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        test "something" do
          x = 1
          y = 2
          assert x + y == 3
        end
      end
      """)

      capture_io(fn -> send(self(), ModifiedTests.find_test_lines(file, [3, 4, 5])) end)
      assert_received [target]
      assert target =~ ":2"
    end
  end

  describe "run/1" do
    test "returns ok when no modified files" do
      # git diff returns no files
      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {"", 0} end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTests.run())
        end)

      assert_received {0, ""}
      assert output =~ "No modified test files"
    end

    @tag :tmp_dir
    test "runs tests for modified files with setup change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "my_test.exs")

      File.write!(file, """
      defmodule MyTest do
        setup do
          {:ok, conn: build_conn()}
        end

        test "something" do
          assert true
        end
      end
      """)

      # git rev-parse for base branch detection
      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      # git diff --name-only returns our file
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)
      # git diff -U0 returns a hunk touching line 2 (setup)
      expect(System, :cmd, fn "git", ["diff", "-U0" | _], _opts -> {"@@ -2,1 +2,1 @@\n", 0} end)
      # mock Port.open for mix test
      expect(CheckEscript.Port, :open, fn "mix", ["test" | args] ->
        assert file in args
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary, :exit_status, args: ["1 test, 0 failures"]
        ])
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTests.run())
        end)

      assert_received {0, ""}
      assert output =~ "setup/describe changed"
    end

    @tag :tmp_dir
    test "runs specific test lines for test-only change", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "my_test.exs")

      File.write!(file, """
      defmodule MyTest do
        test "first" do
          assert 1 == 1
        end

        test "second" do
          assert 2 == 2
        end
      end
      """)

      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)
      # hunk touching line 7 (inside "second" test)
      expect(System, :cmd, fn "git", ["diff", "-U0" | _], _opts -> {"@@ -7,1 +7,1 @@\n", 0} end)

      expect(CheckEscript.Port, :open, fn "mix", ["test" | args] ->
        assert Enum.any?(args, &String.contains?(&1, ":6"))
        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary, :exit_status, args: ["1 test, 0 failures"]
        ])
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTests.run())
        end)

      assert_received {0, ""}
      assert output =~ ":6"
    end
  end
end
