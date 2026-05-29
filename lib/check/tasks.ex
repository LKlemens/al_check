defmodule CheckEscript.Tasks do
  @moduledoc "Task definition, selection, expansion, and partitioning."

  alias CheckEscript.Config

  def define(mock_mode, partitions, test_dir, test_args, repeat, config, coverage) do
    base_tasks = define_base_tasks(mock_mode, config)
    test_tasks = define_test_tasks(mock_mode, partitions, test_dir, test_args, repeat, coverage)
    Map.merge(base_tasks, test_tasks)
  end

  defp define_base_tasks(true, _config) do
    %{
      format: {"Formatting", "echo", ["Format check passed"]},
      compile: {"Compile", "echo", ["Compile check passed"]},
      compile_test: {"Compile (test)", "echo", ["Compile test check passed"]},
      dialyzer: {"Dialyzer", "sh", ["-c", "sleep 2 && echo 'Dialyzer passed'"]},
      credo: {"Credo", "sh", ["-c", "sleep 1 && echo 'Credo passed'"]},
      credo_strict: {"Credo Strict", "sh", ["-c", "sleep 6 && exit 1"]}
    }
  end

  defp define_base_tasks(false, config) do
    checks_config = config["checks"] || Config.default_checks()

    if Map.has_key?(checks_config, "test") do
      IO.puts(
        :stderr,
        "Warning: \"test\" in checks is ignored — use \"test_args\" or --test-args to configure test command"
      )
    end

    base_branch = Config.base_branch(config)

    checks_config
    |> Map.drop(["test"])
    |> Enum.map(fn {key, value} ->
      {name, cmd, args} = Config.parse_check_config(key, value)
      args = replace_base_branch(args, base_branch)
      {String.to_atom(key), {name, cmd, args}}
    end)
    |> Map.new()
  end

  defp define_test_tasks(mock_mode, partitions, test_dir, test_args, repeat, coverage) do
    procs = test_procs(partitions)
    test_path = test_dir || ""
    base_flags = test_args || "--warnings-as-errors"
    repeat_flags = if repeat, do: " --repeat-until-failure #{repeat}", else: ""
    test_flags = base_flags <> repeat_flags

    for partition <- 1..max(partitions, 0)//1, into: %{} do
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
          {test_runner, coverage_flags} = test_runner_cmd(coverage.mod)
          resolved_flags = String.replace(test_flags, "{partition}", to_string(partition))

          {task_name, "sh",
           [
             "-c",
             "ELIXIR_ERL_OPTIONS='+S #{procs}:#{procs}' MIX_TEST_PARTITION=#{partition} mix #{test_runner} #{test_path} #{resolved_flags}#{coverage_flags} --partitions #{partitions}"
           ], partition, partitions}
        end

      {task_key, task_def}
    end
  end

  def select(all_tasks, opts, partitions, config) do
    tasks =
      case {opts[:fast], opts[:only]} do
        {true, _} -> select_fast(all_tasks, config)
        {_, only} when is_binary(only) -> select_only(all_tasks, only, partitions)
        {_, nil} -> select_default(all_tasks, config, partitions)
      end

    if Enum.empty?(tasks) do
      IO.puts(:stderr, "Error: No valid checks specified")
      System.halt(1)
    end

    tasks
  end

  defp select_default(all_tasks, config, partitions) do
    (config["run"] || Config.default_run())
    |> Enum.map(fn name -> String.to_atom(to_string(name)) end)
    |> Enum.flat_map(&expand_check(&1, partitions))
    |> Enum.uniq()
    |> Enum.map(&Map.get(all_tasks, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp select_fast(all_tasks, config) do
    (config["fast"] || Config.default_fast())
    |> Enum.map(fn name -> String.to_atom(to_string(name)) end)
    |> Enum.map(&Map.get(all_tasks, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp select_only(all_tasks, only_string, partitions) do
    only_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.flat_map(&expand_check(&1, partitions))
    |> Enum.uniq()
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
  end

  def build_test_cmd(test_dir, test_args, repeat, partitions, coverage) do
    {runner, _} = test_runner_cmd(coverage.mod)
    cover_flag = if coverage.mod == :native, do: " --cover", else: ""
    parts = ["mix #{runner}#{cover_flag}"]
    parts = if test_dir, do: parts ++ [test_dir], else: parts
    parts = parts ++ [test_args || "--warnings-as-errors"]
    parts = if repeat, do: parts ++ ["--repeat-until-failure #{repeat}"], else: parts
    parts = parts ++ ["--partitions #{partitions}"]
    Enum.join(parts, " ")
  end

  def has_test_tasks?(tasks) do
    Enum.any?(tasks, fn task ->
      name = elem(task, 0)
      String.starts_with?(name, "Tests (")
    end)
  end

  def cap_partitions(partitions, test_dir) do
    dirs = if test_dir, do: String.split(test_dir), else: ["test"]

    test_file_count =
      dirs |> Enum.flat_map(&Path.wildcard("#{&1}/**/*_test.exs")) |> Enum.uniq() |> length()

    cond do
      test_file_count == 0 ->
        IO.puts([IO.ANSI.format([:yellow, "No test files found in #{Enum.join(dirs, ", ")}"])])
        0

      test_file_count < partitions ->
        IO.puts([
          IO.ANSI.format([
            :yellow,
            "Not enough test files for #{partitions} partitions (found #{test_file_count}), using #{test_file_count}"
          ])
        ])

        test_file_count

      true ->
        partitions
    end
  end

  def test_runner_cmd(:native), do: {"test", " --cover"}
  def test_runner_cmd(:coveralls), do: {"coveralls", ""}
  def test_runner_cmd(_), do: {"test", ""}

  def test_procs(0), do: 1

  def test_procs(partitions) do
    schedulers = :erlang.system_info(:schedulers_online)
    procs = floor(schedulers / partitions)
    if procs > 0, do: procs, else: 1
  end

  defp replace_base_branch(args, base_branch) do
    Enum.map(args, fn
      arg when is_binary(arg) -> String.replace(arg, "{base_branch}", base_branch)
      arg -> arg
    end)
  end

  defp expand_check(:test, partitions) when partitions > 0 do
    for partition <- 1..partitions, do: String.to_atom("test_#{partition}")
  end

  defp expand_check(:test, _), do: []

  defp expand_check(check, _partitions), do: [check]
end
