defmodule CheckEscript.ConfigTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Config

  describe "parse_coverage/1" do
    test "parses full config" do
      assert Config.parse_coverage(%{"mod" => "native", "limit" => 80, "html" => true}) ==
               %{mod: :native, limit: 80, html: true, baseline_cmd: nil}
    end

    test "parses coveralls" do
      assert Config.parse_coverage(%{"mod" => "coveralls", "limit" => 50}) ==
               %{mod: :coveralls, limit: 50, html: false, baseline_cmd: nil}
    end

    test "defaults html to false" do
      assert Config.parse_coverage(%{"mod" => "native"}) ==
               %{mod: :native, limit: nil, html: false, baseline_cmd: nil}
    end

    test "returns disabled for nil" do
      assert Config.parse_coverage(nil) == %{mod: false, limit: nil, html: false, baseline_cmd: nil}
    end

    test "returns disabled for false" do
      assert Config.parse_coverage(false) == %{mod: false, limit: nil, html: false, baseline_cmd: nil}
    end

    test "returns disabled for unknown mod" do
      assert Config.parse_coverage(%{"mod" => "unknown"}) ==
               %{mod: false, limit: nil, html: false, baseline_cmd: nil}
    end
  end

  describe "parse_check_config/2" do
    test "parses run string with name" do
      config = %{"name" => "Formatting", "run" => "mix format --check-formatted"}

      assert Config.parse_check_config("format", config) ==
               {"Formatting", "sh", ["-c", "mix format --check-formatted"]}
    end

    test "uses humanized key when name is missing" do
      config = %{"run" => "mix compile --warnings-as-errors"}

      assert Config.parse_check_config("compile_test", config) ==
               {"Compile Test", "sh", ["-c", "mix compile --warnings-as-errors"]}
    end
  end

  describe "humanize_key/1" do
    test "capitalizes and replaces underscores" do
      assert Config.humanize_key("compile_test") == "Compile Test"
    end

    test "single word" do
      assert Config.humanize_key("format") == "Format"
    end

    test "already capitalized" do
      assert Config.humanize_key("credo") == "Credo"
    end
  end

  describe "default_checks/0" do
    test "returns a map with expected keys" do
      checks = Config.default_checks()
      assert is_map(checks)
      assert Map.has_key?(checks, "format")
      assert Map.has_key?(checks, "compile")
      assert Map.has_key?(checks, "credo")
      assert Map.has_key?(checks, "modified_test_modules")
    end

    test "each check has name and run" do
      for {_key, check} <- Config.default_checks() do
        assert Map.has_key?(check, "name")
        assert Map.has_key?(check, "run")
      end
    end
  end

  describe "default_fast/0" do
    test "returns list of strings" do
      fast = Config.default_fast()
      assert is_list(fast)
      assert "format" in fast
      assert "compile" in fast
    end
  end

  describe "load/0" do
    @tag :tmp_dir
    test "returns empty map when no config file exists", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        assert Config.load() == %{}
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "parses valid json config", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      config = %{"partitions" => 5, "max_concurrency" => 8}
      File.write!(Path.join(tmp_dir, ".check.json"), Jason.encode!(config))
      File.cd!(tmp_dir)

      try do
        assert Config.load() == config
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "returns empty map for invalid json", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.write!(Path.join(tmp_dir, ".check.json"), "not json")
      File.cd!(tmp_dir)

      try do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Config.load() == %{}
        end)
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "returns empty map for non-object json", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.write!(Path.join(tmp_dir, ".check.json"), "[1,2,3]")
      File.cd!(tmp_dir)

      try do
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Config.load() == %{}
        end)
      after
        File.cd!(original_dir)
      end
    end
  end

  describe "init/0" do
    @tag :tmp_dir
    test "creates .check.json with valid json", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      try do
        ExUnit.CaptureIO.capture_io(fn ->
          Config.init()
        end)

        path = Path.join(tmp_dir, ".check.json")
        assert File.exists?(path)
        {:ok, decoded} = path |> File.read!() |> Jason.decode()
        assert is_map(decoded)
        assert Map.has_key?(decoded, "checks")
        assert Map.has_key?(decoded, "partitions")
      after
        File.cd!(original_dir)
      end
    end

    @tag :tmp_dir
    test "does not overwrite existing config", %{tmp_dir: tmp_dir} do
      original_dir = File.cwd!()
      path = Path.join(tmp_dir, ".check.json")
      File.write!(path, "existing")
      File.cd!(tmp_dir)

      try do
        ExUnit.CaptureIO.capture_io(fn ->
          Config.init()
        end)

        assert File.read!(path) == "existing"
      after
        File.cd!(original_dir)
      end
    end
  end
end
