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
      check --failed                       # Re-run still-failing tests (updates .check/still_failing.txt)
      check --all-failed                   # Re-run all originally failed tests
      check --watch                        # Monitor test partition files in real-time
      check --test-args '--exclude slow'   # Replace default --warnings-as-errors with custom args
      check --verbose                     # Print test output directly instead of partition status
      check --coverage                    # Show coverage report (cached if unchanged)
      check --no-coverage                 # Run without coverage (overrides .check.json)
      check --repeat 10                   # Run tests with --repeat-until-failure 10 (default: 100)
      check --quiet                       # Disable spinner animation
      check --setup-db / --db-setup        # Run DB setup for each test partition
      check --drop-db / --db-drop         # Drop DB for each test partition
      check --for-partitions 'mix ecto.reset'  # Run any command across partitions
  """

  alias Check.{Config, Coverage, Failed, Fix, Partitions, Runner, Summary, Tasks, Watch}

  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, mock_mode, fix_mode, invalid} = parse_args(args)

    if opts[:quiet], do: Application.put_env(:al_check, :quiet, true)

    reject_invalid_flags(invalid)
    validate_positive(opts[:partitions], "--partitions")
    validate_positive(opts[:repeat], "--repeat")

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
          "Warning: check #{@version} is outdated (dep has #{dep_version}). Run: mix check.update"
        ])
      ])
    end
  end

  defp dispatch(opts, mock_mode, fix_mode, config) do
    command = detect_command(opts, fix_mode)
    run_command(command, opts, mock_mode, config)
  end

  @command_flags [
    :version,
    :init,
    :help,
    :watch,
    :failed,
    :all_failed,
    :coverage,
    :setup_db,
    :db_setup,
    :drop_db,
    :db_drop,
    :for_partitions
  ]

  defp detect_command(opts, fix_mode) do
    found = Enum.find(@command_flags, fn flag -> opts[flag] end)

    cond do
      found == :all_failed -> :failed
      found in [:setup_db, :db_setup, :drop_db, :db_drop, :for_partitions] -> :partitions
      found -> found
      fix_mode -> :fix
      true -> :checks
    end
  end

  defp run_command(:version, _opts, _mock, _config), do: IO.puts("check #{@version}")
  defp run_command(:init, _opts, _mock, _config), do: Config.init()
  defp run_command(:help, _opts, _mock, _config), do: print_help()
  defp run_command(:watch, _opts, _mock, _config), do: Watch.run()
  defp run_command(:failed, opts, _mock, _config), do: Failed.run(opts)
  defp run_command(:coverage, _opts, _mock, config), do: run_coverage(config)
  defp run_command(:partitions, opts, _mock, config), do: run_partition_cmd(opts, config)
  defp run_command(:fix, _opts, _mock, _config), do: Fix.run()
  defp run_command(:checks, opts, mock, config), do: run_checks(opts, mock, config)

  defp run_partition_cmd(opts, config) do
    partitions = opts[:partitions] || config["partitions"] || 3
    Partitions.run_for_all(partition_cmd(opts, config), partitions)
  end

  defp partition_cmd(opts, config) do
    cond do
      opts[:setup_db] || opts[:db_setup] -> config["db_setup"] || "mix ecto.setup"
      opts[:drop_db] || opts[:db_drop] -> config["db_drop"] || "mix ecto.drop"
      opts[:for_partitions] -> opts[:for_partitions]
    end
  end

  defp run_coverage(config) do
    coverage = Config.parse_coverage(config["coverage"])

    if coverage.mod == false do
      IO.puts(:stderr, "Coverage not configured. Set \"coverage\" in .check.json")
      System.halt(1)
    end

    result = Coverage.merge(coverage)
    Coverage.show_modified_files_coverage()

    if result == :failed, do: System.halt(1)
  end

  defp run_checks(opts, mock_mode, config) do
    partitions = opts[:partitions] || config["partitions"] || 3
    max_concurrency = config["max_concurrency"] || 10
    test_dir = parse_dirs(opts[:dir])
    test_args = opts[:test_args] || config["test_args"]
    repeat = opts[:repeat]

    coverage =
      if opts[:coverage] == false,
        do: %{mod: false, limit: nil, html: false, baseline_cmd: nil},
        else: Config.parse_coverage(config["coverage"])

    partitions = if mock_mode, do: partitions, else: Tasks.cap_partitions(partitions, test_dir)

    all_tasks = Tasks.define(mock_mode, partitions, test_dir, test_args, repeat, config, coverage)
    tasks = Tasks.select(all_tasks, opts, partitions, config)

    prepare_test_run(tasks, test_args, coverage)

    verbose = opts[:verbose] || false
    test_cmd = Tasks.build_test_cmd(test_dir, test_args, repeat, partitions, coverage)
    test_opts = %{repeat: repeat, test_args: test_args}

    {results, total_seconds} =
      Runner.run_checks(tasks, test_opts, test_cmd, max_concurrency, verbose)

    Summary.print(results, total_seconds, tasks, coverage)
  end

  defp prepare_test_run(tasks, test_args, coverage) do
    if Tasks.has_test_tasks?(tasks) do
      Failed.save_test_args(test_args_with_cover(test_args, coverage))
      Path.wildcard(".check/test_partition_*.txt") |> Enum.each(&File.rm/1)
      Path.wildcard("cover/*.coverdata") |> Enum.each(&File.rm/1)
    end
  end

  defp test_args_with_cover(nil, %{mod: :native}), do: "--cover"
  defp test_args_with_cover(args, %{mod: :native}), do: "#{args} --cover"
  defp test_args_with_cover(args, _coverage), do: args

  defp parse_args(args) do
    {args, test_args} = extract_test_args(args)
    {args, for_partitions} = extract_flag_with_value(args, "--for-partitions")

    {opts, remaining_args, invalid} =
      OptionParser.parse(args,
        strict: [
          only: :string,
          fix: :boolean,
          fast: :boolean,
          partitions: :integer,
          failed: :boolean,
          all_failed: :boolean,
          dir: :string,
          watch: :boolean,
          verbose: :boolean,
          repeat: :integer,
          help: :boolean,
          init: :boolean,
          version: :boolean,
          coverage: :boolean,
          quiet: :boolean,
          setup_db: :boolean,
          drop_db: :boolean,
          db_setup: :boolean,
          db_drop: :boolean
        ],
        aliases: [h: :help, v: :version]
      )

    opts = if test_args, do: Keyword.put(opts, :test_args, test_args), else: opts
    opts = if for_partitions, do: Keyword.put(opts, :for_partitions, for_partitions), else: opts
    mock_mode = "mock" in remaining_args
    fix_mode = opts[:fix] || false
    {opts, mock_mode, fix_mode, invalid}
  end

  # Extract a flag and its value before OptionParser (value may start with --)
  defp extract_test_args(args), do: extract_flag_with_value(args, "--test-args")

  defp extract_flag_with_value(args, flag) do
    case Enum.split_while(args, &(&1 != flag)) do
      {before, [^flag, value | rest]} -> {before ++ rest, value}
      {before, [^flag]} -> {before, nil}
      {all, []} -> {all, nil}
    end
  end

  defp validate_positive(nil, _flag), do: :ok
  defp validate_positive(n, _flag) when is_integer(n) and n > 0, do: :ok

  defp validate_positive(n, flag) do
    IO.puts(:stderr, "#{flag} must be greater than 0, got: #{n}")
    System.halt(1)
  end

  @allowed_invalid ~w(--repeat)
  @valid_flags ~w(--only --fix --fast --partitions --failed --all-failed --dir --watch --verbose --quiet --repeat --help --init --version --coverage --no-coverage --test-args --setup-db --db-setup --drop-db --db-drop --for-partitions)

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
