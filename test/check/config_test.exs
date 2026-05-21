defmodule CheckEscript.ConfigTest do
  use ExUnit.Case, async: true

  alias CheckEscript.Config

  describe "parse_coverage/1" do
    test "parses full config" do
      assert Config.parse_coverage(%{"mod" => "native", "limit" => 80, "html" => true}) ==
               %{mod: :native, limit: 80, html: true}
    end

    test "parses coveralls" do
      assert Config.parse_coverage(%{"mod" => "coveralls", "limit" => 50}) ==
               %{mod: :coveralls, limit: 50, html: false}
    end

    test "defaults html to false" do
      assert Config.parse_coverage(%{"mod" => "native"}) ==
               %{mod: :native, limit: nil, html: false}
    end

    test "returns disabled for nil" do
      assert Config.parse_coverage(nil) == %{mod: false, limit: nil, html: false}
    end

    test "returns disabled for false" do
      assert Config.parse_coverage(false) == %{mod: false, limit: nil, html: false}
    end

    test "returns disabled for unknown mod" do
      assert Config.parse_coverage(%{"mod" => "unknown"}) ==
               %{mod: false, limit: nil, html: false}
    end
  end

  describe "parse_check_config/2" do
    test "parses run string with name" do
      config = %{"name" => "Formatting", "run" => "mix format --check-formatted"}
      assert Config.parse_check_config("format", config) == {"Formatting", "sh", ["-c", "mix format --check-formatted"]}
    end

    test "uses humanized key when name is missing" do
      config = %{"run" => "mix compile --warnings-as-errors"}
      assert Config.parse_check_config("compile_test", config) == {"Compile Test", "sh", ["-c", "mix compile --warnings-as-errors"]}
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
    end
  end
end
