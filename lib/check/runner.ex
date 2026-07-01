defmodule Check.Runner do
  @moduledoc "Parallel check execution, streaming, and port management."

  alias Check.{Failed, Tasks, UI}

  def run_checks(tasks, test_opts, test_cmd, max_concurrency, verbose) do
    print_header(tasks, test_cmd)

    start_time = System.monotonic_time(:millisecond)
    {:ok, dot_counter_pid} = Agent.start_link(fn -> %{} end)

    results = execute_tasks(tasks, dot_counter_pid, max_concurrency, verbose, test_opts)

    Agent.stop(dot_counter_pid)
    total_seconds = elapsed_seconds(start_time)

    {results, total_seconds}
  end

  # No spinner here: the watch command streams a continuous `tail -f`, so a
  # spinner would only flicker between output lines.
  def stream_port_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        stream_port_output(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  def stream_and_capture_port(port) do
    spinner = Check.Spinner.start()
    {output, status} = do_stream_and_capture_port(port, "", spinner)
    {status, output}
  end

  defp do_stream_and_capture_port(port, acc, spinner) do
    receive do
      {^port, {:data, data}} ->
        Check.Spinner.stop(spinner)
        IO.binwrite(:stdio, data)
        new_spinner = Check.Spinner.start()
        do_stream_and_capture_port(port, acc <> data, new_spinner)

      {^port, {:exit_status, status}} ->
        Check.Spinner.stop(spinner)
        {acc, status}
    end
  end

  def run_check(cmd, args, false) do
    {output, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    {status, output}
  end

  def run_check(cmd, args, true) do
    port = Check.Port.open(cmd, args)
    collect_and_stream_output(port, "")
  end

  defp run_builtin("modified_tests", opts), do: Check.ModifiedTests.run(opts)
  defp run_builtin("modified_test_modules", opts), do: Check.ModifiedTestModules.run(opts)

  defp run_builtin(name, _opts) do
    IO.puts(:stderr, "Unknown builtin: #{name}")
    {1, ""}
  end

  # -- Private --

  defp print_header(tasks, test_cmd) do
    IO.puts("Running code quality checks in parallel...\n")

    if Tasks.has_test_tasks?(tasks) do
      IO.puts([IO.ANSI.format([:cyan, "Test command: #{test_cmd}\n"])])
    end

    schedulers = :erlang.system_info(:schedulers_online)
    IO.puts("Available schedulers: #{schedulers}\n")
  end

  defp execute_tasks(tasks, dot_counter_pid, max_concurrency, verbose, test_opts) do
    task_count = length(tasks)

    if not verbose do
      Enum.each(tasks, fn task ->
        IO.puts("  • #{String.pad_trailing(elem(task, 0), 25)} [RUNNING]")
      end)
    end

    tasks
    |> Enum.with_index()
    |> Task.async_stream(
      fn {task, index} ->
        execute_task(task, index, task_count, dot_counter_pid, verbose, test_opts)
      end,
      timeout: :infinity,
      ordered: false,
      max_concurrency: max_concurrency
    )
    |> Enum.map(fn {:ok, {name, index, status, output, test_count}} ->
      if not verbose, do: UI.update_task_line(index, name, status, task_count, test_count)
      {name, index, status, output}
    end)
    |> tap(&print_builtin_output(tasks, &1))
    |> Enum.map(fn {name, _index, status, output} -> {name, status, output} end)
  end

  # Builtin output is captured during the run (so it can't clobber the status
  # UI); print it below the finalized status lines, in task order.
  defp print_builtin_output(tasks, results) do
    builtin_names =
      for {name, :builtin, _args} <- tasks, into: MapSet.new(), do: name

    results
    |> Enum.filter(fn {name, _index, _status, _output} -> MapSet.member?(builtin_names, name) end)
    |> Enum.sort_by(fn {_name, index, _status, _output} -> index end)
    |> Enum.each(fn {_name, _index, _status, output} ->
      if output not in [nil, ""], do: IO.write(output)
    end)
  end

  defp execute_task(
         {name, cmd, args, partition, total_partitions},
         index,
         task_count,
         dot_counter_pid,
         verbose,
         _test_opts
       ) do
    Process.sleep((rem(index, total_partitions) + 1) * 200)

    {status, output} =
      run_check_with_streaming(
        cmd,
        args,
        index,
        name,
        task_count,
        dot_counter_pid,
        partition,
        verbose
      )

    {total, failures} =
      Agent.get(dot_counter_pid, fn state ->
        {Map.get(state, "partition_#{partition}_total", 0),
         Map.get(state, "partition_#{partition}_failures", 0)}
      end)

    {name, index, status, output, {total, failures}}
  end

  defp execute_task(
         {name, :builtin, args},
         index,
         _task_count,
         _dot_counter_pid,
         _verbose,
         test_opts
       ) do
    # Capture the builtin's stdout so its live output can't corrupt the
    # cursor-based status UI (UI.update_task_line uses relative cursor moves).
    # It is reprinted below the status lines once they are drawn.
    {status, captured} = capture_builtin_output(hd(args), test_opts)
    {name, index, status, captured, nil}
  end

  defp execute_task({name, cmd, args}, index, _task_count, _dot_counter_pid, verbose, _test_opts) do
    {status, output} = run_check(cmd, args, verbose)
    {name, index, status, output, nil}
  end

  defp capture_builtin_output(builtin, test_opts) do
    {:ok, sio} = StringIO.open("")
    group_leader = Process.group_leader()
    previous_quiet = Application.get_env(:al_check, :quiet, false)

    Process.group_leader(self(), sio)
    Application.put_env(:al_check, :quiet, true)

    {status, _output} =
      try do
        run_builtin(builtin, test_opts)
      after
        Process.group_leader(self(), group_leader)
        Application.put_env(:al_check, :quiet, previous_quiet)
      end

    {:ok, {_in, captured}} = StringIO.close(sio)
    {status, captured}
  end

  defp run_check_with_streaming(
         cmd,
         args,
         index,
         name,
         total_tasks,
         dot_counter_pid,
         partition,
         verbose
       ) do
    updater_pid =
      if not verbose do
        spawn_link(fn -> UI.update_loop(index, name, total_tasks, dot_counter_pid) end)
      end

    File.mkdir_p!(".check")
    file_handle = File.open!(".check/test_partition_#{partition}.txt", [:write, :utf8])

    port = Check.Port.open(cmd, args)

    {output, status} =
      collect_port_output(port, "", dot_counter_pid, partition, file_handle, verbose)

    File.close(file_handle)
    if updater_pid, do: send(updater_pid, :stop)

    {determine_final_status(status, output), output}
  end

  def determine_final_status(status, output) do
    # Anchor on the real column-0 ExUnit summary line ("N tests, M failures", possibly
    # prefixed with doctests/properties). Fragments printed inside failure blocks are
    # indented, so they can't masquerade as the summary and flip the classification.
    tests_failed? = Regex.match?(~r/^\d.*, [1-9]\d* failures?\b/m, output)
    tests_passed? = Regex.match?(~r/^\d.*, 0 failures?\b/m, output)
    warnings? = Failed.detect_warnings_in_output(output)

    cond do
      tests_failed? -> failure_status(status)
      # Warnings only fail the run when mix itself treated them as errors
      # (non-zero exit from `--warnings-as-errors`). A clean exit stays a pass,
      # even if the output happens to contain "warning:".
      status != 0 and tests_passed? and warnings? -> :warnings
      status != 0 and Failed.coverage_threshold_failure?(output) -> 0
      true -> status
    end
  end

  defp failure_status(0), do: 1
  defp failure_status(status), do: status

  defp collect_and_stream_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        collect_and_stream_output(port, acc <> data)

      {^port, {:exit_status, status}} ->
        {status, acc}
    end
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
    total_count = count_test_dots(data) + count_failure_markers(data)

    if total_count > 0 do
      Agent.update(dot_counter_pid, fn state ->
        Map.update(state, "partition_#{partition}_total", total_count, &(&1 + total_count))
      end)
    end

    parse_test_summary(data, dot_counter_pid, partition)
  end

  defp count_test_dots(data) do
    data
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.match?(&1, ~r/^[\.\*F]+$/))
    |> Enum.map(fn line -> line |> String.graphemes() |> Enum.count(&(&1 == ".")) end)
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
        Agent.update(dot_counter_pid, fn state ->
          state
          |> Map.put("partition_#{partition}_total", String.to_integer(total_str))
          |> Map.put("partition_#{partition}_failures", String.to_integer(failures_str))
        end)

      _ ->
        :ok
    end
  end

  defp elapsed_seconds(start_time) do
    (System.monotonic_time(:millisecond) - start_time)
    |> Kernel./(1000)
    |> Float.round(1)
  end
end
