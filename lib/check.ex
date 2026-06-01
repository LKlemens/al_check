defmodule Check do
  @moduledoc """
  Runs all code quality checks in parallel.

  See the [Configuration](guides/configuration.md), [Test Partitioning](guides/test-partitioning.md),
  and [Workflows](guides/workflows.md) guides for detailed documentation.

  ## Usage

      check                                # Run all checks
      check -v                             # Show version
      check --init                         # Create .check.json with defaults
      check --help/-h                      # Show this help message
      check --fast                         # Run only fast checks (format, compile, credo)
      check --only format,test             # Run only format and test
      check --only modified_tests          # Run only modified/new tests vs base branch
      check --only modified_test_modules   # Run whole test files modified vs base branch
      check --partitions 2                 # Run tests with 2 partitions (default: 3)
      check --dir test/dir                 # Run tests only from specific directory
      check --dir test/foo,test/bar        # Run tests from multiple directories
      check --fix                          # Apply fixes from stored credo output
      check --failed                       # Re-run only failed tests from previous run
      check --watch                        # Monitor test partition files in real-time
      check --test-args '--exclude slow'   # Replace default --warnings-as-errors with custom args
      check --verbose                     # Print test output directly instead of partition status
      check --coverage                    # Show coverage report (cached if unchanged)
      check --repeat 10                   # Run tests with --repeat-until-failure 10 (default: 100)
  """

  alias Check.{Config, Coverage, Failed, Fix, Runner, Summary, Tasks, Watch}

  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, mock_mode, fix_mode, invalid} = parse_args(args)

    reject_invalid_flags(invalid)

    config =
      case Config.load() do
        {:ok, config} ->
          config

        {:error, msg} ->
          IO.puts(:stderr, msg)
          System.halt(1)
      end

    repeat = resolve_repeat(opts[:repeat], invalid, config)
    opts = Keyword.put(opts, :repeat, repeat)

    check_version_mismatch()
    dispatch(opts, mock_mode, fix_mode, config)
  end

  defp check_version_mismatch do
    dep_mix = Path.join([File.cwd!(), "deps", "al_check", "mix.exs"])

    with true <- File.exists?(dep_mix),
         [_, dep_version] <- Regex.run(~r/@version\s+"([^"]+)"/, File.read!(dep_mix)),
         :gt <- Version.compare(dep_version, @version) do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "Warning: check #{@version} is outdated (dep has #{dep_version}). Run: mix check.install"
        ])
      ])
    end
  end

  defp dispatch(opts, mock_mode, fix_mode, config) do
    cond do
      opts[:version] -> IO.puts("check #{@version}")
      opts[:init] -> Config.init()
      opts[:help] -> print_help()
      opts[:watch] -> Watch.run()
      opts[:failed] -> Failed.run(opts[:repeat])
      opts[:coverage] -> run_coverage(config)
      fix_mode -> Fix.run()
      true -> run_checks(opts, mock_mode, config)
    end
  end

  defp run_coverage(config) do
    coverage = Config.parse_coverage(config["coverage"])

    if coverage.mod == false do
      IO.puts(:stderr, "Coverage not configured. Set \"coverage\" in .check.json")
      System.halt(1)
    end

    case Coverage.merge(coverage) do
      :failed -> System.halt(1)
      :ok -> :ok
    end
  end

  defp run_checks(opts, mock_mode, config) do
    partitions = opts[:partitions] || config["partitions"] || 3
    max_concurrency = config["max_concurrency"] || 10
    test_dir = parse_dirs(opts[:dir])
    test_args = opts[:test_args] || config["test_args"]
    repeat = opts[:repeat]
    coverage = Config.parse_coverage(config["coverage"])
    partitions = if mock_mode, do: partitions, else: Tasks.cap_partitions(partitions, test_dir)

    all_tasks = Tasks.define(mock_mode, partitions, test_dir, test_args, repeat, config, coverage)
    tasks = Tasks.select(all_tasks, opts, partitions, config)

    if Tasks.has_test_tasks?(tasks) do
      Failed.save_test_args(test_args)
      Path.wildcard(".check/test_partition_*.txt") |> Enum.each(&File.rm/1)
    end

    verbose = opts[:verbose] || false
    test_cmd = Tasks.build_test_cmd(test_dir, test_args, repeat, partitions, coverage)
    test_opts = %{repeat: repeat, test_args: test_args}

    {results, total_seconds} =
      Runner.run_checks(tasks, test_opts, test_cmd, max_concurrency, verbose)

    Summary.print(results, total_seconds, tasks, coverage)
  end

  defp parse_args(args) do
    {opts, remaining_args, invalid} =
      OptionParser.parse(args,
        strict: [
          only: :string,
          fix: :boolean,
          fast: :boolean,
          partitions: :integer,
          failed: :boolean,
          dir: :string,
          watch: :boolean,
          verbose: :boolean,
          repeat: :integer,
          help: :boolean,
          init: :boolean,
          version: :boolean,
          coverage: :boolean,
          test_args: :string
        ],
        aliases: [h: :help, v: :version]
      )

    mock_mode = "mock" in remaining_args
    fix_mode = opts[:fix] || false
    {opts, mock_mode, fix_mode, invalid}
  end

  @allowed_invalid ~w(--repeat --test-args)
  @valid_flags ~w(--only --fix --fast --partitions --failed --dir --watch --verbose --repeat --help --init --version --coverage --test-args)

  defp reject_invalid_flags(invalid) do
    unknown =
      invalid
      |> Enum.map(fn {switch, _} -> switch end)
      |> Enum.reject(&(&1 in @allowed_invalid))
      |> Enum.filter(&(String.starts_with?(&1, "--") and not String.contains?(&1, " ")))

    if Enum.any?(unknown) do
      Enum.each(unknown, fn flag ->
        IO.puts(:stderr, "Unknown flag: #{flag}")
        suggest_similar(flag)
      end)

      IO.puts(:stderr, "Run 'check --help' for available options")
      System.halt(1)
    end
  end

  defp suggest_similar(flag) do
    case find_closest_flag(flag) do
      {match, score} when score > 0.8 -> IO.puts(:stderr, "Did you mean #{match}?")
      _ -> :ok
    end
  end

  defp find_closest_flag(flag) do
    @valid_flags
    |> Enum.map(fn valid -> {valid, String.jaro_distance(flag, valid)} end)
    |> Enum.max_by(fn {_, score} -> score end)
  end

  defp resolve_repeat(repeat, _invalid, _config) when is_integer(repeat), do: repeat

  defp resolve_repeat(nil, invalid, config) do
    default = config["default_repeat"] || 100
    invalid_switches = Enum.map(invalid, fn {switch, _} -> switch end)
    if "--repeat" in invalid_switches, do: default, else: nil
  end

  defp print_help do
    @moduledoc
    |> String.split("## ")
    |> Enum.find(&String.starts_with?(&1, "Usage"))
    |> then(&IO.puts("## " <> &1))
  end

  defp parse_dirs(nil), do: nil
  defp parse_dirs(dir), do: dir |> String.split(",") |> Enum.map_join(" ", &String.trim/1)
end
