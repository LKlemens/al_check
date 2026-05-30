defmodule CheckEscript do
  @moduledoc """
  Runs all code quality checks in parallel.

  ## Usage

      check                                # Run all checks
      check -v                             # Show version
      check --init                         # Create .check.json with defaults
      check --help/-h                      # Show this help message
      check --fast                         # Run only fast checks (format, compile, credo)
      check --only format,test             # Run only format and test
      check --only credo                   # Run credo and credo_strict
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

  ## Available checks

    - format        - mix format --check-formatted
    - compile       - mix compile --warnings-as-errors
    - compile_test  - MIX_ENV=test mix compile --warnings-as-errors
    - dialyzer      - mix dialyzer
    - credo         - mix credo --all
    - credo_strict  - mix credo --strict --only readability --all
    - test          - mix test (runs in partitions for parallel execution)

  ## Fast checks

  The --fast flag runs only: format, compile, compile_test, credo, credo_strict
  (skips: dialyzer, test)

  ## Test partitioning

  Tests run in parallel partitions (default: 3). Each partition uses its own database.
  Use --partitions N to customize the number of partitions based on your CPU cores.

  ### Database setup for partitions

  Each partition needs its own database to avoid deadlocks and connection limit issues.
  In `config/runtime.exs`, use `MIX_TEST_PARTITION` to create per-partition database URLs:

      # config/runtime.exs
      partition = System.get_env("MIX_TEST_PARTITION", "")

      test_database_url =
        System.get_env("TEST_DATABASE_URL")
        |> URI.parse()
        |> then(fn uri ->
          db_name = String.trim_leading(uri.path || "", "/")
          Map.put(uri, :path, "/\#{db_name}\#{partition}")
        end)
        |> URI.to_string()

      config :my_app, MyApp.Repo, url: test_database_url

  This creates databases like `my_app_test1`, `my_app_test2`, etc.

  ### Avoiding DB connection limits

  With N partitions, your database needs at least `N * pool_size` connections.
  Increase `max_connections` in PostgreSQL if you see connection errors:

      # PostgreSQL config (or docker run command)
      postgres -c max_connections=400 -c shared_buffers=2GB

  Consider reducing `pool_size` per partition in `config/test.exs`:

      config :my_app, MyApp.Repo, pool_size: 10

  With 3 partitions and pool_size 10, you need at least 30 connections.

  ### Scheduler tuning

  AlCheck automatically limits BEAM schedulers per partition to avoid CPU contention:
  `schedulers_online / partitions`. With 10 cores and 3 partitions, each gets ~3 schedulers.

  ## Failed test workflow

  When tests fail, failed test locations are automatically saved to check/failed_tests.txt:

      check --only test     # Run tests and save failures
      cat .check/failed_tests.txt # View failed tests
      check --failed        # Re-run only the failed tests

  ## Auto-fix workflow

  Format and credo failures are tracked in .check/ directory for later use with --fix:

      check --only format,credo  # Run checks and store failures
      check --fix                # Apply fixes from stored failures

  The --fix command will:
  - Check if format failed previously (.check/.format_failed marker) and run mix format
  - Apply credo fixes from stored output files (.check/credo.txt, .check/credo_strict.txt)

  ## Configuration file

  Create a `.check.json` in your project root to customize behavior.
  Override the path via the `CHECK_CONFIG` environment variable.

      {
        "fast": ["format", "compile", "compile_test", "credo"],
        "partitions": 3,
        "max_concurrency": 10,
        "test_args": "--warnings-as-errors",
        "default_repeat": 100,
        "coverage": {"mod": "native", "limit": 80, "html": false},
        "checks": {
          "format": {"name": "Formatting", "run": "mix format --check-formatted"},
          "credo": {"name": "Credo", "run": "mix credo --all"}
        }
      }

  Name defaults to a capitalized version of the key (e.g. "compile_test" → "Compile Test").

  Coverage: `{"mod": "native", "limit": 80, "html": false, "baseline_cmd": "git show origin/main:coverage.txt"}`.
  `mod` selects the tool (`native` = built-in --cover, `coveralls` = excoveralls).
  `limit` is optional — fails the check if total coverage is below the given percentage.
  `html` (default: false) — when true, generates full HTML report; when false, kills early after getting %.
  `baseline_cmd` is optional — shell command that outputs baseline coverage % (e.g. from main).
  When set, shows coverage delta vs baseline after each run.
  Partition coverage is merged into a single report after all partitions complete.

  All fields are optional. CLI flags override config values.
  When `checks` is provided, it replaces all built-in checks (test partitions are always added).

  ## Adding custom checks

  Add a check to the `"checks"` section in `.check.json`:

      "checks": {
        "sobelow": {"name": "Security", "run": "mix sobelow --config"},
        "gettext": {"name": "Gettext", "run": "mix gettext.extract --check-up-to-date"}
      }

  Each check needs a `run` key with the shell command to execute. The `name` is optional
  and defaults to a capitalized version of the key.

  ### Shell commands

  The `run` string is executed via `sh -c`, so pipes, env vars, and shell features work:

      "compile_test": {"run": "MIX_ENV=test mix compile --warnings-as-errors"}

  Use `{base_branch}` placeholder for the auto-detected base branch:

      "diff_check": {"run": "git diff {base_branch}... --stat"}

  ### Builtin checks

  For checks that need Elixir logic (not just a shell command), use the `builtin:` prefix:

      "modified_tests": {"run": "builtin:modified_tests"}

  Available builtins:
    - `builtin:modified_tests` — runs only changed test lines vs base branch
    - `builtin:modified_test_modules` — runs whole modified test files vs base branch

  ### Selecting which checks run by default

  The `"run"` key lists which checks execute when running `check` without flags:

      "run": ["format", "compile", "credo", "test"]

  Checks not in `"run"` are still available via `--only`:

      check --only sobelow
      check --only modified_tests
  """

  alias CheckEscript.{Config, Coverage, Failed, Fix, Runner, Summary, Tasks, Watch}

  @version Mix.Project.config()[:version]

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, mock_mode, fix_mode, invalid} = parse_args(args)

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

    dispatch(opts, mock_mode, fix_mode, config)
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
