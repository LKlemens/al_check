defmodule CheckEscript.Runner do
  @moduledoc "Parallel check execution, streaming, and port management."

  alias CheckEscript.{Failed, Tasks, UI}

  def run_checks(tasks, _repeat, test_cmd, max_concurrency, verbose) do
    IO.puts("Running code quality checks in parallel...\n")

    if Tasks.has_test_tasks?(tasks) do
      IO.puts([IO.ANSI.format([:cyan, "Test command: #{test_cmd}\n"])])
    end

    schedulers = :erlang.system_info(:schedulers_online)
    IO.puts("Available schedulers: #{schedulers}\n")

    if not verbose do
      Enum.each(tasks, fn task ->
        name = elem(task, 0)
        IO.puts("  • #{String.pad_trailing(name, 25)} [RUNNING]")
      end)
    end

    start_time = System.monotonic_time(:millisecond)
    {:ok, dot_counter_pid} = Agent.start_link(fn -> %{} end)

    results =
      tasks
      |> Enum.with_index()
      |> Task.async_stream(
        fn {task, index} ->
          case task do
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
                  partition,
                  verbose
                )

              {total, failures} =
                Agent.get(dot_counter_pid, fn state ->
                  total = Map.get(state, "partition_#{partition}_total", 0)
                  failures = Map.get(state, "partition_#{partition}_failures", 0)
                  {total, failures}
                end)

              {name, index, status, output, {total, failures}}

            {name, cmd, args} ->
              {status, output} = run_check(cmd, args, verbose)
              {name, index, status, output, nil}
          end
        end,
        timeout: :infinity,
        ordered: false,
        max_concurrency: max_concurrency
      )
      |> Enum.map(fn {:ok, result} ->
        case result do
          {name, index, status, output, test_count} ->
            if not verbose,
              do: UI.update_task_line(index, name, status, length(tasks), test_count)

            {name, status, output}
        end
      end)

    Agent.stop(dot_counter_pid)

    total_time = System.monotonic_time(:millisecond) - start_time
    total_seconds = Float.round(total_time / 1000, 1)

    {results, total_seconds}
  end

  def run_check(cmd, args, false) do
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    {status, output}
  end

  def run_check(cmd, args, true) do
    port =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    collect_and_stream_output(port, "")
  end

  defp collect_and_stream_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        collect_and_stream_output(port, acc <> data)

      {^port, {:exit_status, status}} ->
        {status, acc}
    end
  end

  defp run_check_with_streaming(cmd, args, index, name, total_tasks, dot_counter_pid, partition, verbose) do
    parent = self()

    updater_pid =
      if not verbose do
        spawn_link(fn ->
          UI.update_loop(parent, index, name, total_tasks, dot_counter_pid)
        end)
      end

    File.mkdir_p!(".check")
    output_file = ".check/test_partition_#{partition}.txt"
    file_handle = File.open!(output_file, [:write, :utf8])

    port =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {output, status} = collect_port_output(port, "", dot_counter_pid, partition, file_handle, verbose)

    File.close(file_handle)

    if updater_pid, do: send(updater_pid, :stop)

    tests_passed? = Regex.match?(~r/\d+ tests?, 0 failures/, output)

    final_status =
      cond do
        status == 0 and Failed.detect_warnings_in_output(output) -> :warnings
        status != 0 and tests_passed? and Failed.detect_warnings_in_output(output) -> :warnings
        status != 0 and Failed.coverage_threshold_failure?(output) -> 0
        true -> status
      end

    {final_status, output}
  end

  defp collect_port_output(port, acc, dot_counter_pid, partition, file_handle, verbose) do
    receive do
      {^port, {:data, data}} ->
        IO.write(file_handle, data)
        if verbose, do: IO.binwrite(:stdio, data)
        update_test_progress(data, dot_counter_pid, partition)
        collect_port_output(port, acc <> data, dot_counter_pid, partition, file_handle, verbose)

      {^port, {:exit_status, status}} ->
        {acc, status}
    end
  end

  defp update_test_progress(data, dot_counter_pid, partition) do
    total_count = count_test_progress(data)

    if total_count > 0 do
      Agent.update(dot_counter_pid, fn state ->
        key = "partition_#{partition}_total"
        Map.update(state, key, total_count, &(&1 + total_count))
      end)
    end

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
end
