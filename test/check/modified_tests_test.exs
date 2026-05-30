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

    test "stops at describe boundary" do
      lines = [
        "  describe \"first\" do",
        "    test \"a\" do",
        "      assert true",
        "    end",
        "  end",
        "",
        "  describe \"second\" do",
        "    b = 12",
        "    test \"b\" do",
        "      assert true",
        "    end",
        "  end"
      ]

      # line 8 (b = 12) is inside "second" describe, above test "b" at line 9
      # should NOT find test "a" at line 2 from the "first" describe
      assert ModifiedTests.find_enclosing_test(lines, 8) == nil
    end

    test "finds test within same describe" do
      lines = [
        "  describe \"feature\" do",
        "    test \"works\" do",
        "      x = 1",
        "      assert x == 1",
        "    end",
        "  end"
      ]

      assert ModifiedTests.find_enclosing_test(lines, 4) == 2
    end
  end

  describe "find_enclosing_describe/2" do
    test "finds describe above changed line" do
      lines = [
        "defmodule MyTest do",
        "  describe \"feature\" do",
        "    setup do",
        "      {:ok, conn: build_conn()}",
        "    end",
        "    test \"works\" do",
        "      assert true",
        "    end",
        "  end",
        "end"
      ]

      assert ModifiedTests.find_enclosing_describe(lines, 6) == 2
      assert ModifiedTests.find_enclosing_describe(lines, 3) == 2
    end

    test "returns nil when not inside describe" do
      lines = [
        "defmodule MyTest do",
        "  setup do",
        "    :ok",
        "  end",
        "end"
      ]

      assert ModifiedTests.find_enclosing_describe(lines, 2) == nil
    end
  end

  describe "run/1 - setup inside describe runs describe block" do
    @tag :tmp_dir
    test "setup inside describe runs describe block, not whole file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        describe "feature" do
          setup do
            {:ok, conn: build_conn()}
          end

          test "works" do
            assert true
          end
        end

        test "other" do
          assert true
        end
      end
      """)

      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)
      # hunk touching line 3 (setup inside describe)
      expect(System, :cmd, fn "git", ["diff", "-U0" | _], _opts -> {"@@ -3,1 +3,1 @@\n", 0} end)

      expect(CheckEscript.Port, :open, fn "mix", ["test" | args] ->
        # should run describe block (line 2), not whole file
        assert Enum.any?(args, &String.contains?(&1, ":2"))
        refute file in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      capture_io(fn -> send(self(), ModifiedTests.run()) end)
      assert_received {0, ""}
    end

    @tag :tmp_dir
    test "module-level setup runs whole file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "test.exs")

      File.write!(file, """
      defmodule MyTest do
        setup do
          {:ok, conn: build_conn()}
        end

        test "works" do
          assert true
        end
      end
      """)

      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)
      # hunk touching line 2 (module-level setup)
      expect(System, :cmd, fn "git", ["diff", "-U0" | _], _opts -> {"@@ -2,1 +2,1 @@\n", 0} end)

      expect(CheckEscript.Port, :open, fn "mix", ["test" | args] ->
        # should run whole file
        assert file in args

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      output = capture_io(fn -> send(self(), ModifiedTests.run()) end)
      assert_received {0, ""}
      assert output =~ "module-level setup changed"
    end

    @tag :tmp_dir
    test "describe line change runs describe block", %{tmp_dir: tmp_dir} do
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

      expect(System, :cmd, fn "git", ["rev-parse" | _], _opts -> {"", 0} end)
      expect(System, :cmd, fn "git", ["diff", "--name-only" | _], _opts -> {file <> "\n", 0} end)
      # hunk touching line 2 (describe line)
      expect(System, :cmd, fn "git", ["diff", "-U0" | _], _opts -> {"@@ -2,1 +2,1 @@\n", 0} end)

      expect(CheckEscript.Port, :open, fn "mix", ["test" | args] ->
        assert Enum.any?(args, &String.contains?(&1, ":2"))

        Port.open({:spawn_executable, System.find_executable("echo")}, [
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      capture_io(fn -> send(self(), ModifiedTests.run()) end)
      assert_received {0, ""}
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
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
        ])
      end)

      output =
        capture_io(fn ->
          send(self(), ModifiedTests.run())
        end)

      assert_received {0, ""}
      assert output =~ "setup changed"
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
          :binary,
          :exit_status,
          args: ["1 test, 0 failures"]
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
