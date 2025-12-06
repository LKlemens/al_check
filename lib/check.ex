defmodule CheckEscript do
  @moduledoc """
  Runs all code quality checks in parallel.

  ## Usage

      check                                # Run all checks
      check --help/-h                      # Show this help message
      check --fast                         # Run only fast checks (format, compile, credo)
      check --only format,test             # Run only format and test
      check --only credo                   # Run credo and credo_strict
      check --partitions 2                 # Run tests with 2 partitions (default: 3)
      check --dir test/dir                 # Run tests only from specific directory
      check --fix                          # Apply fixes from stored credo output
      check --failed                       # Re-run only failed tests from previous run
      check --watch                        # Monitor test partition files in real-time
      check --test-args "--exclude slow"   # Replace default --warnings-as-errors with custom args
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

  Tests run in parallel partitions (default: 5). Each partition uses its own database.
  Use --partitions N to customize the number of partitions based on your CPU cores.

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
  """

  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, mock_mode, fix_mode} = parse_args(args)

    cond do
      # if --help flag, print help and exit
      opts[:help] ->
        print_help()

      # if --watch flag, monitor test partition files
      opts[:watch] ->
        watch_partition_files()

      # if --failed flag, run failed tests from previous run
      opts[:failed] ->
        run_failed_tests(opts[:repeat])

      # if --fix flag, read stored outputs and apply fixes
      fix_mode ->
        apply_fixes_from_stored_output()

      # normal check flow
      true ->
        partitions = opts[:partitions] || 3
        test_dir = opts[:dir]
        test_args = opts[:test_args]
        repeat = opts[:repeat]
        all_tasks = define_tasks(mock_mode, partitions, test_dir, test_args, repeat)
        tasks = select_tasks(all_tasks, opts, partitions)
        if has_test_tasks?(tasks), do: save_test_args(test_args)
        test_cmd = build_test_cmd(test_dir, test_args, repeat, partitions)
        {results, total_seconds} = run_checks(tasks, repeat, test_cmd)
        print_summary(results, total_seconds, tasks)
    end
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
          test_args: :string,
          repeat: :integer,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    mock_mode = "mock" in remaining_args
    fix_mode = opts[:fix] || false
    repeat = resolve_repeat(opts[:repeat], invalid)
    opts = Keyword.put(opts, :repeat, repeat)
    {opts, mock_mode, fix_mode}
  end

  defp resolve_repeat(repeat, _invalid) when is_integer(repeat), do: repeat

  defp resolve_repeat(nil, invalid) do
    invalid_switches = Enum.map(invalid, fn {switch, _} -> switch end)
    if "--repeat" in invalid_switches, do: 100, else: nil
  end

  defp print_help do
    @moduledoc
    |> String.split("## ")
    |> Enum.find(&String.starts_with?(&1, "Usage"))
    |> then(&IO.puts("## " <> &1))
  end

  defp define_tasks(mock_mode, partitions, test_dir, test_args, repeat) do
    base_tasks =
      if mock_mode do
        # mock tasks for testing
        %{
          format: {"Formatting", "echo", ["Format check passed"]},
          compile: {"Compile", "echo", ["Compile check passed"]},
          compile_test: {"Compile (test)", "echo", ["Compile test check passed"]},
          dialyzer: {"Dialyzer", "sh", ["-c", "sleep 2 && echo 'Dialyzer passed'"]},
          credo: {"Credo", "sh", ["-c", "sleep 1 && echo 'Credo passed'"]},
          credo_strict: {"Credo Strict", "sh", ["-c", "sleep 6 && exit 1"]}
        }
      else
        # real tasks
        %{
          format: {"Formatting", "mix", ["format", "--check-formatted"]},
          compile: {"Compile", "mix", ["compile", "--warnings-as-errors"]},
          compile_test:
            {"Compile (test)", "sh", ["-c", "MIX_ENV=test mix compile --warnings-as-errors"]},
          dialyzer: {"Dialyzer", "mix", ["dialyzer"]},
          credo: {"Credo", "mix", ["credo", "--all"]},
          credo_strict:
            {"Credo Strict", "mix", ["credo", "--strict", "--only", "readability", "--all"]}
        }
      end

    test_procs = test_procs(partitions)
    test_path = test_dir || ""
    # use --warnings-as-errors by default, but allow override via --test-args
    base_flags = test_args || "--warnings-as-errors"
    repeat_flags = if repeat, do: " --repeat-until-failure #{repeat}", else: ""
    test_flags = base_flags <> repeat_flags

    # generate test partition tasks
    test_tasks =
      for partition <- 1..partitions, into: %{} do
        task_key = String.to_atom("test_#{partition}")
        task_name = "Tests (#{partition}/#{partitions})"

        task_def =
          if mock_mode do
            {task_name, "sh",
             [
               "-c",
               "sleep 2 && echo '............\n\nFinished in 0.1s\n20 tests, 0 failures' && exit 0"
             ], partition, partitions}
          else
            {task_name, "sh",
             [
               "-c",
               "ELIXIR_ERL_OPTIONS='+S #{test_procs}:#{test_procs}' MIX_TEST_PARTITION=#{partition} mix test #{test_path} #{test_flags} --partitions #{partitions}"
             ], partition, partitions}
          end

        {task_key, task_def}
      end

    Map.merge(base_tasks, test_tasks)
  end

  defp select_tasks(all_tasks, opts, partitions) do
    tasks =
      case {opts[:fast], opts[:only]} do
        # --fast overrides --only
        {true, _} ->
          # run only: format, compile, compile_test, credo, credo_strict
          [:format, :compile, :compile_test, :credo, :credo_strict]
          |> Enum.map(&Map.get(all_tasks, &1))
          |> Enum.reject(&is_nil/1)

        # normal --only filter (when --fast is not provided or false)
        {_, only_string} when is_binary(only_string) ->
          # parse comma-separated check names
          selected_checks =
            only_string
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&String.to_atom/1)

          # expand checks (e.g., credo -> [credo, credo_strict], test -> [test_1, test_2, ...])
          expanded_checks =
            selected_checks
            |> Enum.flat_map(&expand_check(&1, partitions))
            |> Enum.uniq()

          # filter and preserve order
          expanded_checks
          |> Enum.map(fn check ->
            case Map.get(all_tasks, check) do
              nil ->
                IO.puts(:stderr, "Warning: Unknown check '#{check}', skipping...")
                nil

              task ->
                task
            end
          end)
          |> Enum.reject(&is_nil/1)

        # no options, run all (when both --fast and --only are not provided)
        {_, nil} ->
          Map.values(all_tasks)
      end

    if Enum.empty?(tasks) do
      IO.puts(:stderr, "Error: No valid checks specified")
      System.halt(1)
    end

    tasks
  end

  defp build_test_cmd(test_dir, test_args, repeat, partitions) do
    parts = ["mix test"]
    parts = if test_dir, do: parts ++ [test_dir], else: parts
    parts = parts ++ [test_args || "--warnings-as-errors"]
    parts = if repeat, do: parts ++ ["--repeat-until-failure #{repeat}"], else: parts
    parts = parts ++ ["--partitions #{partitions}"]
    Enum.join(parts, " ")
  end

  defp run_checks(tasks, _repeat, test_cmd) do
    IO.puts("Running code quality checks in parallel...\n")

    # print test command if test tasks are present
    if has_test_tasks?(tasks) do
      IO.puts([IO.ANSI.format([:cyan, "Test command: #{test_cmd}\n"])])
    end

    # show scheduler information
    schedulers = :erlang.system_info(:schedulers_online)
    IO.puts("Available schedulers: #{schedulers}\n")

    # print initial status
    Enum.each(tasks, fn task ->
      name = elem(task, 0)
      IO.puts("  • #{String.pad_trailing(name, 25)} [RUNNING]")
    end)

    # start time tracking
    start_time = System.monotonic_time(:millisecond)

    # start dot counter agent
    {:ok, dot_counter_pid} = Agent.start_link(fn -> %{} end)

    # run all tasks in parallel and update UI as each completes
    results =
      tasks
      |> Enum.with_index()
      |> Task.async_stream(
        fn {task, index} ->
          case task do
            # test partition task (5-tuple)
            {name, cmd, args, partition, total_partitions} ->
              sleep = (rem(index, total_partitions) + 1) * 1000
              Process.sleep(sleep)

              {status, output} =
                run_check_with_streaming(
                  cmd,
                  args,
                  index,
                  name,
                  length(tasks),
                  dot_counter_pid,
                  partition
                )

              # get final test counts for this partition
              {total, failures} =
                Agent.get(dot_counter_pid, fn state ->
                  total = Map.get(state, "partition_#{partition}_total", 0)
                  failures = Map.get(state, "partition_#{partition}_failures", 0)
                  {total, failures}
                end)

              {name, index, status, output, {total, failures}}

            # regular task (3-tuple)
            {name, cmd, args} ->
              {status, output} = run_check(cmd, args)
              {name, index, status, output, nil}
          end
        end,
        timeout: :infinity,
        ordered: false,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, result} ->
        case result do
          {name, index, status, output, test_count} ->
            update_task_line(index, name, status, length(tasks), test_count)
            {name, status, output}
        end
      end)

    # stop dot counter agent
    Agent.stop(dot_counter_pid)

    # calculate total time
    total_time = System.monotonic_time(:millisecond) - start_time
    total_seconds = Float.round(total_time / 1000, 1)

    {results, total_seconds}
  end

  defp print_summary(results, total_seconds, tasks) do
    # move cursor to bottom
    IO.write("\n")

    # save credo outputs to files
    save_credo_outputs(results)

    # save format failure marker
    save_format_failure_marker(results)

    # merge test partition outputs into single file
    merge_partition_outputs(results)

    # extract and save failed tests only when test tasks ran
    if has_test_tasks?(tasks) do
      failed_tests = extract_failed_tests()
      save_failed_tests(failed_tests)
    end

    failed_checks = Enum.filter(results, fn {_name, status, _output} -> status != 0 end)

    IO.puts("\nCompleted in #{total_seconds}s")

    if Enum.empty?(failed_checks) do
      IO.puts([IO.ANSI.format([:green, "\n✓ All checks passed!"])])
    else
      IO.puts([IO.ANSI.format([:red, "\n✗ #{length(failed_checks)} check(s) failed"])])
      print_failure_details(failed_checks)
      System.halt(1)
    end
  end

  defp save_credo_outputs(results) do
    File.mkdir_p!(".check")

    results
    |> Enum.filter(fn {name, _status, _output} ->
      name in ["Credo", "Credo Strict"]
    end)
    |> Enum.each(fn {name, _status, output} ->
      filename =
        case name do
          "Credo" -> ".check/credo.txt"
          "Credo Strict" -> ".check/credo_strict.txt"
        end

      File.write!(filename, output)
    end)
  end

  defp save_format_failure_marker(results) do
    File.mkdir_p!(".check")

    format_failed? =
      Enum.any?(results, fn {name, status, _output} ->
        name == "Formatting" and status != 0
      end)

    if format_failed? do
      File.write!(".check/.format_failed", "")
    else
      # delete marker if format passed
      File.rm(".check/.format_failed")
    end
  end

  defp print_failure_details(failed_checks) do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("FAILURE DETAILS")
    IO.puts(String.duplicate("=", 60))

    Enum.each(failed_checks, fn {name, _status, output} ->
      IO.puts([IO.ANSI.format([:red, :bright, "\n#{name} failed:"])])
      IO.puts(String.duplicate("-", 40))

      if String.starts_with?(name, "Tests (") do
        # test partition - show only summary line
        summary = extract_test_summary(output)
        IO.puts(summary)
        IO.puts([IO.ANSI.format([:yellow, "\nFull test output saved to check_tests.txt"])])
      else
        # show all error output for non-test checks
        lines =
          output
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))

        Enum.each(lines, fn line ->
          # color code certain types of output
          formatted_line =
            cond do
              String.contains?(line, "** ") ->
                [IO.ANSI.format([:red, line])]

              String.contains?(line, "warning:") ->
                [IO.ANSI.format([:yellow, line])]

              String.contains?(line, "error:") ->
                [IO.ANSI.format([:red, line])]

              String.contains?(line, "┃") or String.contains?(line, "│") ->
                [IO.ANSI.format([:cyan, line])]

              true ->
                line
            end

          IO.puts(formatted_line)
        end)
      end
    end)
  end

  defp merge_partition_outputs(results) do
    # find all test partition results
    partition_results =
      results
      |> Enum.filter(fn {name, _status, _output} ->
        String.starts_with?(name, "Tests (")
      end)
      |> Enum.sort_by(fn {name, _status, _output} ->
        # extract partition number from name like "Tests (3/5)"
        case Regex.run(~r/Tests \((\d+)\/\d+\)/, name) do
          [_, partition_str] -> String.to_integer(partition_str)
          _ -> 0
        end
      end)

    if Enum.any?(partition_results) do
      timestamp = DateTime.utc_now() |> DateTime.to_string()

      content =
        [
          "Test Output - Generated at #{timestamp}",
          String.duplicate("=", 60),
          ""
        ] ++
          Enum.flat_map(partition_results, fn {name, _status, output} ->
            partition_num =
              case Regex.run(~r/Tests \((\d+)\/(\d+)\)/, name) do
                [_, p, t] -> "#{p}/#{t}"
                _ -> "?"
              end

            [
              "\nPARTITION #{partition_num}",
              String.duplicate("-", 60),
              output,
              ""
            ]
          end)

      File.mkdir_p!(".check")
      File.write!(".check/check_tests.txt", Enum.join(content, "\n"))

      # keep partition files for reference - users may want to review individual partition outputs
      # partition files: .check/test_partition_1.txt, .check/test_partition_2.txt, etc.
    end
  end

  defp extract_test_summary(output) when is_binary(output) do
    # look for ExUnit summary line like "108 tests, 1 failure, 107 excluded"
    case Regex.run(~r/(\d+ tests?, \d+ failures?(, \d+ excluded)?.*)/m, output) do
      [_, summary | _] -> summary
      nil -> "See .check/check_tests.txt for details"
    end
  end

  defp extract_test_summary(_output) do
    "See .check/check_tests.txt for details"
  end

  defp run_check(cmd, args) do
    # suppress output unless there's an error
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    {status, output}
  end

  defp run_check_with_streaming(cmd, args, index, name, total_tasks, dot_counter_pid, partition) do
    # start a process to update UI periodically
    parent = self()

    updater_pid =
      spawn_link(fn ->
        update_loop(parent, index, name, total_tasks, dot_counter_pid)
      end)

    # create check directory and open file for real-time streaming
    File.mkdir_p!(".check")
    output_file = ".check/test_partition_#{partition}.txt"
    file_handle = File.open!(output_file, [:write, :utf8])

    # run command and collect output with streaming
    port =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {output, status} = collect_port_output(port, "", dot_counter_pid, partition, file_handle)

    # close file handle
    File.close(file_handle)

    # signal updater to stop
    send(updater_pid, :stop)

    # fail if warnings detected in output (even if tests passed)
    final_status =
      if status == 0 and detect_warnings_in_output(output) do
        1
      else
        status
      end

    {final_status, output}
  end

  defp collect_port_output(port, acc, dot_counter_pid, partition, file_handle) do
    receive do
      {^port, {:data, data}} ->
        # write data to file immediately for real-time streaming
        IO.write(file_handle, data)
        update_test_progress(data, dot_counter_pid, partition)
        collect_port_output(port, acc <> data, dot_counter_pid, partition, file_handle)

      {^port, {:exit_status, status}} ->
        {acc, status}
    end
  end

  defp update_test_progress(data, dot_counter_pid, partition) do
    # update running test count
    total_count = count_test_progress(data)

    if total_count > 0 do
      Agent.update(dot_counter_pid, fn state ->
        key = "partition_#{partition}_total"
        Map.update(state, key, total_count, &(&1 + total_count))
      end)
    end

    # parse final ExUnit summary if present
    parse_test_summary(data, dot_counter_pid, partition)
  end

  defp count_test_progress(data) do
    dot_count = count_test_dots(data)
    failure_count = count_failure_markers(data)
    dot_count + failure_count
  end

  defp count_test_dots(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.match?(&1, ~r/^[\.\*F]+$/))
    |> Enum.map(fn line ->
      line |> String.graphemes() |> Enum.count(&(&1 == "."))
    end)
    |> Enum.sum()
  end

  defp count_failure_markers(data) do
    data
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^\s+\d+\)\s+test\s+/, &1))
  end

  defp parse_test_summary(data, dot_counter_pid, partition) do
    # parse ExUnit summary line: "108 tests, 3 failures"
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, data) do
      [_, total_str, failures_str] ->
        total = String.to_integer(total_str)
        failures = String.to_integer(failures_str)

        Agent.update(dot_counter_pid, fn state ->
          state
          |> Map.put("partition_#{partition}_total", total)
          |> Map.put("partition_#{partition}_failures", failures)
        end)

      _ ->
        :ok
    end
  end

  defp update_loop(parent, index, name, total_tasks, dot_counter_pid) do
    receive do
      :stop -> :ok
    after
      1000 ->
        # update UI every second
        # extract partition number from task name like "Tests (3/5)"
        test_counts =
          case Regex.run(~r/Tests \((\d+)\/\d+\)/, name) do
            [_, partition_str] ->
              Agent.get(dot_counter_pid, fn state ->
                total = Map.get(state, "partition_#{partition_str}_total", 0)
                failures = Map.get(state, "partition_#{partition_str}_failures", 0)
                {total, failures}
              end)

            _ ->
              nil
          end

        update_task_line(index, name, :running, total_tasks, test_counts)
        update_loop(parent, index, name, total_tasks, dot_counter_pid)
    end
  end

  defp check_and_fix_format do
    if File.exists?(".check/.format_failed") do
      IO.puts([IO.ANSI.format([:red, "✗ Format check failed previously"])])
      IO.puts([IO.ANSI.format([:yellow, "Running mix format to fix..."])])

      {output, status} = System.cmd("mix", ["format"], stderr_to_stdout: true)

      if status == 0 do
        File.rm(".check/.format_failed")
        IO.puts([IO.ANSI.format([:green, "✓ Format fixed successfully"])])
      else
        IO.puts(output)
        IO.puts([IO.ANSI.format([:red, "✗ Format fix failed"])])
        System.halt(1)
      end
    else
      IO.puts([IO.ANSI.format([:green, "✓ Format check passed"])])
    end
  end

  defp apply_fixes_from_stored_output do
    IO.puts("Checking for failures to fix...\n")

    # check and fix format issues first
    check_and_fix_format()

    IO.puts("\nReading stored credo outputs from check/...\n")

    # read credo output files
    files =
      [".check/credo.txt", ".check/credo_strict.txt"]
      |> Enum.filter(&File.exists?/1)
      |> Enum.flat_map(fn file ->
        content = File.read!(file)
        extract_files_from_credo_output(content)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.empty?(files) do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "No credo errors found. Maybe rerun 'check --only credo'."
        ]),
        IO.ANSI.reset()
      ])
    else
      IO.puts("Found #{length(files)} file(s) with issues:\n")
      Enum.each(files, fn file -> IO.puts("  - #{file}") end)

      IO.puts([
        "\n",
        IO.ANSI.format([:yellow, "Running mix recode on #{length(files)} file(s)..."]),
        IO.ANSI.reset(),
        "\n"
      ])

      # run recode
      {output, status} = System.cmd("mix", ["recode" | files], stderr_to_stdout: true)
      IO.puts(output)

      if status == 0 do
        IO.puts([
          IO.ANSI.format([:green, "\n✓ Auto-fixes applied successfully"]),
          IO.ANSI.reset()
        ])
      else
        IO.puts([IO.ANSI.format([:red, "\n✗ Recode exited with errors"]), IO.ANSI.reset()])
        System.halt(1)
      end
    end
  end

  defp extract_files_from_credo_output(output) do
    # match lines like: "  ┃   lib/foo/bar.ex:123:5" or "lib/foo/bar.ex:123"
    ~r/^\s*┃?\s+([^\s:]+\.exs?):\d+/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, file] -> file end)
  end

  defp extract_failed_tests do
    if File.exists?(".check/check_tests.txt") do
      content = File.read!(".check/check_tests.txt")

      # extract actual test failures
      # match patterns like:
      #   1) test description (Module.Name)
      #      test/path/to/file.exs:123
      failures =
        ~r/\d+\)\s+test\s+.*?\n\s+(test\/[^\s:]+\.exs):(\d+)/m
        |> Regex.scan(content)
        |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)

      # extract warning locations
      warnings = extract_warning_locations(content)

      # combine and deduplicate
      (failures ++ warnings) |> Enum.uniq()
    else
      []
    end
  end

  defp extract_warning_locations(content) do
    # match warning location lines like:
    #   └─ test/path/to/file.exs:16:5: ModuleName."test name"/1
    ~r/└─ (test\/[^\s:]+\.exs):(\d+)/m
    |> Regex.scan(content)
    |> Enum.map(fn [_, file, line] -> "#{file}:#{line}" end)
  end

  defp save_failed_tests(failed_tests) do
    if Enum.any?(failed_tests) do
      File.mkdir_p!(".check")
      content = Enum.join(failed_tests, "\n")
      File.write!(".check/failed_tests.txt", content)
      IO.puts([IO.ANSI.format([:yellow, "\nFailed tests saved to .check/failed_tests.txt"])])
    end
  end

  defp run_failed_tests(repeat) do
    failed_tests_file = ".check/failed_tests.txt"

    unless File.exists?(failed_tests_file) do
      IO.puts([
        IO.ANSI.format([:red, "No failed tests found. Run 'check --only test' first."]),
        IO.ANSI.reset()
      ])

      System.halt(1)
    end

    failed_tests =
      failed_tests_file
      |> File.read!()
      |> String.split("\n", trim: true)

    if Enum.empty?(failed_tests) do
      IO.puts([
        IO.ANSI.format([:green, "No failed tests to run!"]),
        IO.ANSI.reset()
      ])
    else
      IO.puts("Running #{length(failed_tests)} failed test(s)...\n")

      # run mix test with all failed test files, streaming output
      test_args = read_saved_test_args()
      repeat_args = if repeat, do: ["--repeat-until-failure", to_string(repeat)], else: []
      all_args = ["test"] ++ test_args ++ repeat_args ++ failed_tests
      test_cmd = "mix " <> Enum.join(all_args, " ")
      IO.puts([IO.ANSI.format([:cyan, "Test command: #{test_cmd}\n"])])

      port =
        Port.open({:spawn_executable, System.find_executable("mix")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: all_args
        ])

      status = stream_port_output(port)

      if status == 0 do
        IO.puts([
          IO.ANSI.format([:green, "\n✓ All previously failed tests now pass!"]),
          IO.ANSI.reset()
        ])
      else
        IO.puts([
          IO.ANSI.format([:red, "\n✗ Some tests still failing"]),
          IO.ANSI.reset()
        ])

        System.halt(1)
      end
    end
  end

  defp watch_partition_files do
    # check if partition files exist
    partition_files = Path.wildcard(".check/test_partition_*.txt")

    if Enum.empty?(partition_files) do
      IO.puts([
        IO.ANSI.format([
          :yellow,
          "No test partition files found in .check/ directory.\n",
          "Run tests first with: check --only test"
        ]),
        IO.ANSI.reset()
      ])

      System.halt(1)
    end

    IO.puts([
      IO.ANSI.format([:green, "Watching #{length(partition_files)} test partition file(s)..."]),
      IO.ANSI.reset(),
      "\n"
    ])

    # run tail -f -q on all partition files
    port =
      Port.open({:spawn_executable, System.find_executable("tail")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-f", "-q", "-n", "+1" | partition_files]
      ])

    stream_port_output(port)
  end

  defp stream_port_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        stream_port_output(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  # expand check names to include related checks
  # e.g., credo expands to both credo and credo_strict
  # test expands to all partitions
  defp expand_check(:compile, _partitions), do: [:compile, :compile_test]
  defp expand_check(:credo, _partitions), do: [:credo, :credo_strict]

  defp expand_check(:test, partitions) do
    for partition <- 1..partitions do
      String.to_atom("test_#{partition}")
    end
  end

  defp expand_check(check, _partitions), do: [check]

  # check if any of the tasks are test-related
  defp has_test_tasks?(tasks) do
    Enum.any?(tasks, fn task ->
      name = elem(task, 0)
      String.starts_with?(name, "Tests (")
    end)
  end

  defp save_test_args(test_args) do
    File.mkdir_p!(".check")
    test_flags = test_args || "--warnings-as-errors"
    File.write!(".check/test_args.txt", test_flags)
  end

  defp read_saved_test_args do
    case File.read(".check/test_args.txt") do
      {:ok, content} -> content |> String.trim() |> String.split()
      {:error, _} -> ["--warnings-as-errors"]
    end
  end

  defp update_task_line(index, name, status, total_tasks, test_counts) do
    # calculate how many lines up we need to go from current position
    lines_up = total_tasks - index

    {icon, color, text} = format_task_status(status, test_counts)

    # save cursor position, move up, clear line, write status, restore cursor
    IO.write([
      "\e[s",
      "\e[#{lines_up}A",
      "\e[2K",
      IO.ANSI.format([
        color,
        "  #{icon} #{String.pad_trailing(name, 25)} #{text}\n"
      ]),
      "\e[u"
    ])
  end

  defp format_task_status(status, test_counts) do
    case {status, test_counts} do
      # running state with test counts
      {:running, {total, _failures}} when total > 0 ->
        {"•", :yellow, "[RUNNING - #{total} tests]"}

      # running state without test counts yet
      {:running, _} ->
        {"•", :yellow, "[RUNNING]"}

      # success with test counts
      {0, {total, _failures}} when total > 0 ->
        {"✓", :green, "[OK - #{total} tests]"}

      # success without test counts
      {0, _} ->
        {"✓", :green, "[OK]"}

      # failure with test counts and failures
      {_, {total, failures}} when failures > 0 ->
        {"✗", :red, "[FAILED - #{failures}/#{total} tests]"}

      # failure with test counts but no specific failure count
      {_, {total, 0}} when total > 0 ->
        {"✗", :red, "[FAILED - #{total} tests]"}

      # failure without test counts (shouldn't happen for tests, but handle it)
      _ ->
        {"✗", :red, "[FAILED]"}
    end
  end

  defp test_procs(partitions) do
    schedulers = :erlang.system_info(:schedulers_online)
    test_procs = floor(schedulers / partitions)
    if test_procs > 0, do: test_procs, else: 1
  end

  defp detect_warnings_in_output(output) do
    String.contains?(output, "warning:")
  end
end
