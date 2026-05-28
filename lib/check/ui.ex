defmodule CheckEscript.UI do
  @moduledoc "Status line updates, task formatting, and ANSI helpers."

  def update_task_line(index, name, status, total_tasks, test_counts) do
    lines_up = total_tasks - index
    {icon, color, text} = format_task_status(status, test_counts)

    IO.write([
      "\e[s",
      "\e[#{lines_up}A",
      "\e[2K",
      IO.ANSI.format([color, "  #{icon} #{String.pad_trailing(name, 25)} #{text}\n"]),
      "\e[u"
    ])
  end

  def format_task_status(:running, {total, _}) when total > 0,
    do: {"•", :white, "[RUNNING - #{total} tests]"}

  def format_task_status(:running, _),
    do: {"•", :white, "[RUNNING]"}

  def format_task_status(0, {total, _}) when total > 0,
    do: {"✓", :green, "[OK - #{total} tests]"}

  def format_task_status(0, _),
    do: {"✓", :green, "[OK]"}

  def format_task_status(:warnings, {total, _}) when total > 0,
    do: {"!", :yellow, "[WARNINGS - #{total} tests]"}

  def format_task_status(:warnings, _),
    do: {"!", :yellow, "[WARNINGS]"}

  def format_task_status(_, {total, failures}) when failures > 0,
    do: {"✗", :red, "[FAILED - #{failures}/#{total} tests]"}

  def format_task_status(_, {total, 0}) when total > 0,
    do: {"✗", :red, "[FAILED - #{total} tests]"}

  def format_task_status(_, _),
    do: {"✗", :red, "[FAILED]"}

  def update_loop(index, name, total_tasks, dot_counter_pid) do
    receive do
      :stop -> :ok
    after
      1000 ->
        test_counts = get_test_counts(name, dot_counter_pid)
        update_task_line(index, name, :running, total_tasks, test_counts)
        update_loop(index, name, total_tasks, dot_counter_pid)
    end
  end

  defp get_test_counts(name, dot_counter_pid) do
    case Regex.run(~r/Tests \((\d+)\/\d+\)/, name) do
      [_, partition_str] ->
        Agent.get(dot_counter_pid, fn state ->
          {Map.get(state, "partition_#{partition_str}_total", 0),
           Map.get(state, "partition_#{partition_str}_failures", 0)}
        end)

      _ ->
        nil
    end
  end
end
