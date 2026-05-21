defmodule CheckEscript.Coverage do
  @moduledoc "Coverage merging, caching, and threshold checking."

  @coverage_cache_path ".check/coverage_cache"

  def merge(%{mod: false}), do: :ok

  def merge(%{mod: :native, limit: limit, html: html}) do
    IO.puts([IO.ANSI.format([:cyan, "\nMerging coverage data..."])])

    current_hash = coverdata_hash()

    case read_cache(current_hash) do
      {:ok, cached_output} ->
        IO.puts([IO.ANSI.format([:cyan, "(cached)"])])
        check(cached_output, "cover/", limit)

      :miss ->
        port =
          Port.open({:spawn_executable, System.find_executable("mix")}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["test.coverage"]
          ])

        output =
          if html do
            {out, _status} = collect_port_until_exit(port, "")
            out
          else
            {out, _status} = collect_coverage_output(port, "")
            out
          end

        write_cache(current_hash, output)
        check(output, "cover/", limit)
    end
  end

  def merge(%{mod: :coveralls, limit: limit}) do
    IO.puts([IO.ANSI.format([:cyan, "\nMerging coverage data..."])])

    {output, _status} =
      System.cmd("mix", ["coveralls", "--import-cover", "cover/"], stderr_to_stdout: true)

    check(output, "cover/", limit)
  end

  # Stream output from mix test.coverage, kill once Total line is found
  defp collect_coverage_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        if String.contains?(acc, "| Total") do
          Port.close(port)

          receive do
            {^port, {:exit_status, status}} -> {acc, status}
          after
            1000 -> {acc, 0}
          end
        else
          collect_coverage_output(port, acc)
        end

      {^port, {:exit_status, status}} ->
        {acc, status}
    end
  end

  defp collect_port_until_exit(port, acc) do
    receive do
      {^port, {:data, data}} -> collect_port_until_exit(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    end
  end

  def check(output, dir, limit) do
    case parse_total_percentage(output) do
      nil ->
        IO.puts([IO.ANSI.format([:yellow, "Warning: Could not parse coverage from output"])])
        IO.puts(output)
        :ok

      pct ->
        report_coverage(pct, dir, limit)
    end
  end

  defp parse_total_percentage(output) do
    case Regex.run(~r/(\d+\.?\d*)%\s*\|\s*Total|Coverage:\s+(\d+\.?\d*)%/, output) do
      [_, percentage, ""] -> String.to_float(percentage)
      [_, "", percentage] -> String.to_float(percentage)
      [_, percentage] -> String.to_float(percentage)
      _ -> nil
    end
  end

  defp report_coverage(pct, dir, limit) when is_number(limit) and pct < limit do
    IO.puts([IO.ANSI.format([:red, "✗ Coverage: #{pct}% (limit: #{limit}%) | Report: #{dir}"])])
    :failed
  end

  defp report_coverage(pct, dir, _limit) do
    color = coverage_color(pct)
    IO.puts([IO.ANSI.format([color, "✓ Coverage: #{pct}% | Report: #{dir}"])])
    :ok
  end

  defp coverage_color(pct) when pct >= 80, do: :green
  defp coverage_color(pct) when pct >= 50, do: :yellow
  defp coverage_color(_pct), do: :red

  defp coverdata_hash do
    Path.wildcard("cover/*.coverdata")
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:md5), fn path, acc ->
      :crypto.hash_update(acc, File.read!(path))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp read_cache(current_hash) do
    hash_file = @coverage_cache_path <> ".hash"
    output_file = @coverage_cache_path <> ".txt"

    if File.exists?(hash_file) and File.exists?(output_file) do
      cached_hash = File.read!(hash_file) |> String.trim()

      if cached_hash == current_hash do
        {:ok, File.read!(output_file)}
      else
        :miss
      end
    else
      :miss
    end
  end

  defp write_cache(hash, output) do
    File.mkdir_p!(".check")
    File.write!(@coverage_cache_path <> ".hash", hash)
    File.write!(@coverage_cache_path <> ".txt", output)
  end
end
