defmodule Check.Config do
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
    "modified_tests" => %{
      "name" => "Modified Tests",
      "run" => "builtin:modified_tests"
    },
    "modified_test_modules" => %{
      "name" => "Modified Test Modules",
      "run" => "builtin:modified_test_modules"
    }
  }

  @default_run ["format", "compile", "compile_test", "dialyzer", "credo", "credo_strict", "test"]
  @default_fast ["format", "compile", "compile_test", "credo", "credo_strict"]

  @default_config Jason.encode!(
                    %{
                      "run" => @default_run,
                      "fast" => @default_fast,
                      "partitions" => 3,
                      "max_concurrency" => 10,
                      "test_args" => "--warnings-as-errors",
                      "default_repeat" => 100,
                      "fix" => [
                        %{"run" => "mix format"},
                        %{"run" => "mix recode", "files" => ".check/credo*.txt"}
                      ],
                      "db_setup" => "mix ecto.setup",
                      "db_drop" => "mix ecto.drop",
                      "update" => ["mix deps.update al_check", "mix check.install"],
                      "coverage" => %{"mod" => "native", "limit" => 80, "html" => false},
                      "checks" => @default_checks
                    },
                    pretty: true
                  )

  def default_checks, do: @default_checks
  def default_run, do: @default_run
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
      IO.puts([IO.ANSI.format([:green, "Created #{config_path}\n"])])

      IO.puts([
        IO.ANSI.format([
          :yellow,
          "Tip: Add your version manager's reshim to \"update\" in .check.json:\n" <>
            "  asdf:  \"asdf reshim\"\n" <>
            "  mise:  \"mise reshim\"\n" <>
            "  rtx:   \"rtx reshim\""
        ])
      ])
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

  def parse_check_config(key, %{"run" => "builtin:" <> builtin} = config) do
    name = config["name"] || humanize_key(key)
    {name, :builtin, [builtin]}
  end

  def parse_check_config(key, %{"run" => run} = config) do
    name = config["name"] || humanize_key(key)
    {name, "sh", ["-c", run]}
  end

  def base_branch(config, opts \\ []) do
    config["base_branch"] || detect_base_branch(opts)
  end

  @base_branch_candidates ["main", "master", "origin/main", "origin/master"]

  defp detect_base_branch(opts) do
    case Enum.find(@base_branch_candidates, &branch_exists?/1) do
      nil ->
        if Keyword.get(opts, :warn, false) do
          IO.puts(
            :stderr,
            "Could not detect base branch (tried #{Enum.join(@base_branch_candidates, ", ")}). Set \"base_branch\" in .check.json"
          )
        end

        nil

      branch ->
        if Keyword.get(opts, :log, false) do
          IO.puts("Detected base git branch: #{branch}")
        end

        branch
    end
  end

  defp branch_exists?(name) do
    match?(
      {_, 0},
      System.cmd("git", ["rev-parse", "--verify", "--quiet", name], stderr_to_stdout: true)
    )
  end

  def humanize_key(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @known_keys ~w(run fast partitions max_concurrency test_args default_repeat coverage checks base_branch fix db_setup db_drop update)
  @known_coverage_keys ~w(mod limit html baseline_cmd)
  @known_check_keys ~w(name run)

  defp warn_unknown_keys(config) do
    warn_keys(config, @known_keys, "")
    warn_coverage_keys(config["coverage"])
    warn_check_entries(config["checks"])
  end

  defp warn_coverage_keys(coverage) when is_map(coverage),
    do: warn_keys(coverage, @known_coverage_keys, "coverage.")

  defp warn_coverage_keys(_), do: :ok

  defp warn_check_entries(checks) when is_map(checks) do
    Enum.each(checks, fn
      {name, config} when is_map(config) ->
        warn_keys(config, @known_check_keys, "checks.#{name}.")

      _ ->
        :ok
    end)
  end

  defp warn_check_entries(_), do: :ok

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
