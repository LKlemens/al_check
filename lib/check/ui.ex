defmodule CheckEscript.UI do
  @moduledoc "Status line updates, task formatting, and ANSI helpers."

  def update_task_line(index, name, status, total_tasks, test_counts) do
    lines_up = total_tasks - index

    {icon, color, text} = format_task_status(status, test_counts)

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

  def format_task_status(status, test_counts) do
    case {status, test_counts} do
      {:running, {total, _failures}} when total > 0 ->
        {"•", :yellow, "[RUNNING - #{total} tests]"}

      {:running, _} ->
        {"•", :yellow, "[RUNNING]"}

      {0, {total, _failures}} when total > 0 ->
        {"✓", :green, "[OK - #{total} tests]"}

      {0, _} ->
        {"✓", :green, "[OK]"}

      {_, {total, failures}} when failures > 0 ->
        {"✗", :red, "[FAILED - #{failures}/#{total} tests]"}

      {:warnings, {total, _}} when total > 0 ->
        {"!", :yellow, "[WARNINGS - #{total} tests]"}

      {:warnings, _} ->
        {"!", :yellow, "[WARNINGS]"}

      {_, {total, 0}} when total > 0 ->
        {"✗", :red, "[FAILED - #{total} tests]"}

      _ ->
        {"✗", :red, "[FAILED]"}
    end
  end

  def update_loop(parent, index, name, total_tasks, dot_counter_pid) do
    receive do
      :stop -> :ok
    after
      1000 ->
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
end
