defmodule CheckEscript.Config do
  @moduledoc "Config loading, parsing, initialization, and defaults."

  @default_checks %{
    "format" => %{"name" => "Formatting", "run" => "mix format --check-formatted"},
    "compile" => %{"name" => "Compile", "run" => "mix compile --warnings-as-errors"},
    "compile_test" => %{
      "name" => "Compile (test)",
      "run" => "MIX_ENV=test mix compile --warnings-as-errors"
    },
    "dialyzer" => %{"name" => "Dialyzer", "run" => "mix dialyzer"},
    "credo" => %{"name" => "Credo", "run" => "mix credo --all"},
    "credo_strict" => %{
      "name" => "Credo Strict",
      "run" => "mix credo --strict --only readability --all"
    },
    "modified_test_modules" => %{
      "name" => "Modified Test Modules",
      "run" =>
        "files=$(git diff --name-only --diff-filter=d master... -- 'test/**/*_test.exs'); if [ -z \"$files\" ]; then echo 'No modified test files on this branch'; else echo \"Running: \n$files\"; echo $files | xargs mix test; fi"
    }
  }

  @default_fast ["format", "compile", "compile_test", "credo", "credo_strict"]

  @default_config Jason.encode!(
                    %{
                      "fast" => @default_fast,
                      "partitions" => 3,
                      "max_concurrency" => 10,
                      "test_args" => "--warnings-as-errors",
                      "default_repeat" => 100,
                      "coverage" => %{"mod" => "native", "limit" => 80, "html" => false},
                      "checks" => @default_checks
                    },
                    pretty: true
                  )

  def default_checks, do: @default_checks
  def default_fast, do: @default_fast

  def load do
    default_path = Path.join(File.cwd!(), ".check.json")

    config_path =
      case System.get_env("CHECK_CONFIG") do
        path when is_binary(path) and path != "" -> path
        _ -> default_path
      end

    if File.exists?(config_path) do
      case config_path |> File.read!() |> Jason.decode() do
        {:ok, config} when is_map(config) ->
          warn_unknown_keys(config)
          {:ok, config}

        {:ok, _} ->
          {:error, "#{config_path} must contain a JSON object"}

        {:error, reason} ->
          {:error, "Failed to parse #{config_path}: #{inspect(reason)}"}
      end
    else
      {:ok, %{}}
    end
  end

  def init do
    config_path = Path.join(File.cwd!(), ".check.json")

    if File.exists?(config_path) do
      IO.puts([IO.ANSI.format([:yellow, "#{config_path} already exists"])])
    else
      File.write!(config_path, @default_config)
      IO.puts([IO.ANSI.format([:green, "Created #{config_path}"])])
    end
  end

  def parse_coverage(%{"mod" => mod} = config) do
    %{
      mod: parse_coverage_mod(mod),
      limit: config["limit"],
      html: config["html"] || false,
      baseline_cmd: config["baseline_cmd"]
    }
  end

  def parse_coverage(_), do: %{mod: false, limit: nil, html: false, baseline_cmd: nil}

  def parse_check_config(key, %{"run" => run} = config) do
    name = config["name"] || humanize_key(key)
    {name, "sh", ["-c", run]}
  end

  def humanize_key(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @known_keys ~w(fast partitions max_concurrency test_args default_repeat coverage checks)
  @known_coverage_keys ~w(mod limit html baseline_cmd)
  @known_check_keys ~w(name run)

  defp warn_unknown_keys(config) do
    warn_keys(config, @known_keys, "")

    if is_map(config["coverage"]) do
      warn_keys(config["coverage"], @known_coverage_keys, "coverage.")
    end

    if is_map(config["checks"]) do
      Enum.each(config["checks"], fn {check_name, check_config} ->
        if is_map(check_config) do
          warn_keys(check_config, @known_check_keys, "checks.#{check_name}.")
        end
      end)
    end
  end

  defp warn_keys(map, known, prefix) do
    unknown = Map.keys(map) -- known

    Enum.each(unknown, fn key ->
      IO.puts(:stderr, "Warning: Unknown config key \"#{prefix}#{key}\" in .check.json")
    end)
  end

  defp parse_coverage_mod("native"), do: :native
  defp parse_coverage_mod("coveralls"), do: :coveralls
  defp parse_coverage_mod(_), do: false
end
