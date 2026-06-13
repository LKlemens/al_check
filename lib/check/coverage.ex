defmodule Check.Coverage do
  @moduledoc "Coverage merging, caching, and threshold checking."

  @coverage_cache_path ".check/coverage_cache"

  def merge(%{mod: false}), do: :ok

  def merge(%{mod: :native, html: html} = coverage) do
    IO.puts([IO.ANSI.format([:cyan, "\nMerging coverage data..."])])

    current_hash = coverdata_hash()

    case read_cache(current_hash) do
      {:ok, cached_output} ->
        IO.puts([IO.ANSI.format([:cyan, "(cached)"])])
        check(cached_output, "cover/", coverage)

      :miss ->
        port = Check.Port.open("mix", ["test.coverage"])

        output =
          if html do
            {out, _status} = collect_port_until_exit(port, "")
            out
          else
            {out, _status} = collect_coverage_output(port, "")
            out
          end

        write_cache(current_hash, output)
        check(output, "cover/", coverage)
    end
  end

  def merge(%{mod: :coveralls} = coverage) do
    IO.puts([IO.ANSI.format([:cyan, "\nMerging coverage data..."])])

    {output, _status} =
      System.cmd("mix", ["coveralls", "--import-cover", "cover/"], stderr_to_stdout: true)

    check(output, "cover/", coverage)
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
            100 -> {acc, 0}
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

  def check(output, dir, coverage) when is_map(coverage) do
    case parse_total_percentage(output) do
      nil ->
        IO.puts([IO.ANSI.format([:yellow, "Warning: Could not parse coverage from output"])])
        IO.puts(output)
        :ok

      percentage ->
        result = report_coverage(percentage, dir, coverage.limit)
        compare_baseline(percentage, coverage.baseline_cmd)
        result
    end
  end

  # backward compat for direct limit value
  def check(output, dir, limit) do
    check(output, dir, %{limit: limit, baseline_cmd: nil})
  end

  defp parse_total_percentage(output) do
    case Regex.run(~r/(\d+\.?\d*)%\s*\|\s*Total|Coverage:\s+(\d+\.?\d*)%/, output) do
      [_, percentage, ""] -> String.to_float(percentage)
      [_, "", percentage] -> String.to_float(percentage)
      [_, percentage] -> String.to_float(percentage)
      _ -> nil
    end
  end

  defp report_coverage(percentage, dir, limit) when is_number(limit) and percentage < limit do
    IO.puts([
      IO.ANSI.format([:red, "✗ Coverage: #{percentage}% (limit: #{limit}%) | Report: #{dir}"])
    ])

    :failed
  end

  defp report_coverage(percentage, dir, _limit) do
    color = if percentage >= 80, do: :green, else: :yellow
    IO.puts([IO.ANSI.format([color, "✓ Coverage: #{percentage}% | Report: #{dir}"])])
    :ok
  end

  defp compare_baseline(_percentage, nil), do: :ok

  defp compare_baseline(percentage, baseline_cmd) do
    case System.cmd("sh", ["-c", baseline_cmd], stderr_to_stdout: true) do
      {output, 0} ->
        case Float.parse(String.trim(output)) do
          {baseline, _} ->
            print_delta(percentage, baseline)

          :error ->
            IO.puts([
              IO.ANSI.format([
                :yellow,
                "Warning: Could not parse baseline coverage from: #{String.trim(output)}"
              ])
            ])
        end

      {error, _} ->
        IO.puts([
          IO.ANSI.format([:yellow, "Warning: Baseline command failed: #{String.trim(error)}"])
        ])
    end
  end

  defp print_delta(percentage, baseline) do
    delta = Float.round(percentage - baseline, 2)

    cond do
      delta > 0 ->
        IO.puts([IO.ANSI.format([:green, "  Coverage: +#{delta}% vs baseline (#{baseline}%)"])])

      delta < 0 ->
        IO.puts([IO.ANSI.format([:red, "  Coverage: #{delta}% vs baseline (#{baseline}%)"])])

      true ->
        IO.puts([IO.ANSI.format([:cyan, "  Coverage: same as baseline (#{baseline}%)"])])
    end
  end

  def maybe_merge_and_show_modified do
    case Check.Config.load() do
      {:ok, config} ->
        coverage = Check.Config.parse_coverage(config["coverage"])

        if coverage.mod != false do
          # merge without threshold/baseline — just collect the data
          merge_silent(coverage)
          show_modified_files_coverage()
        end

      _ ->
        :ok
    end
  end

  defp merge_silent(%{mod: :native}) do
    current_hash = coverdata_hash()

    case read_cache(current_hash) do
      {:ok, _cached} ->
        :ok

      :miss ->
        port = Check.Port.open("mix", ["test.coverage"])
        # collect all output silently — don't print anything
        {output, _status} = collect_port_until_exit(port, "")
        write_cache(current_hash, output)
    end
  end

  defp merge_silent(_), do: :ok

  def show_modified_files_coverage do
    cache_file = @coverage_cache_path <> ".txt"

    config =
      case Check.Config.load() do
        {:ok, c} -> c
        _ -> %{}
      end

    with {:ok, output} <- File.read(cache_file),
         base_branch when is_binary(base_branch) <- Check.Config.base_branch(config) do
      print_modified_coverage(output, base_branch)
    end
  end

  defp print_modified_coverage(output, base_branch) do
    new_modules = get_ex_files_by_filter(base_branch, "A") |> modules_from_files()

    # Diffing across two revisions can surface an added-then-modified file in
    # both groups; keep it only under "new".
    modified_modules =
      (get_ex_files_by_filter(base_branch, "M") |> modules_from_files()) -- new_modules

    new_lines = filter_coverage_lines(output, new_modules)
    modified_lines = filter_coverage_lines(output, modified_modules)

    print_coverage_group("Coverage of new files:", new_lines, :green)
    print_coverage_group("Coverage of modified files:", modified_lines, :yellow)
  end

  defp modules_from_files(files), do: Enum.flat_map(files, &extract_modules_from_file/1)

  defp print_coverage_group(_title, [], _color), do: :ok

  defp print_coverage_group(title, lines, color) do
    IO.puts([IO.ANSI.format([color, "\n#{title}"])])
    Enum.each(lines, fn line -> IO.puts(linkify_module(line)) end)

    case avg_percentage(lines) do
      nil -> :ok
      avg -> IO.puts([IO.ANSI.format([color, "  Average: #{avg}%"])])
    end
  end

  defp avg_percentage(lines) do
    percentages =
      lines
      |> Enum.map(fn line ->
        case Regex.run(~r/(\d+\.?\d*)%/, line) do
          [_, pct] -> parse_number(pct)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(percentages) do
      nil
    else
      (Enum.sum(percentages) / length(percentages)) |> Float.round(2)
    end
  end

  defp parse_number(str) do
    case Float.parse(str) do
      {num, _} ->
        num

      :error ->
        case Integer.parse(str) do
          {num, _} -> num * 1.0
          :error -> nil
        end
    end
  end

  # Make module name a clickable link to the HTML coverage report (OSC 8 hyperlinks)
  defp linkify_module(line) do
    case Regex.run(~r/\|\s*([\w.]+)\s*\|/, line) do
      [_, module] ->
        html_path = Path.join([File.cwd!(), "cover", "#{module}.html"])

        if File.exists?(html_path) do
          link = "\e]8;;file://#{html_path}\e\\#{module}\e]8;;\e\\"
          String.replace(line, module, link)
        else
          line
        end

      _ ->
        line
    end
  end

  defp get_ex_files_by_filter(base_branch, filter) do
    base_branch
    |> diff_revisions()
    |> Enum.flat_map(&run_name_diff(&1, filter))
    |> Enum.uniq()
  end

  # Revisions to diff "lib" files against, depending on whether we're sitting on
  # the base branch itself. `base...HEAD` (three-dot) collapses to nothing when
  # the current branch *is* the base, so committing straight to main would never
  # report any modified files.
  #
  #   - feature branch: branch commits since base (base...HEAD) + uncommitted (HEAD)
  #   - base branch: last commit and uncommitted (HEAD~1), or just uncommitted on a root commit
  defp diff_revisions(base_branch) do
    if Check.Git.current_branch() == base_branch do
      if Check.Git.parent_commit?(), do: ["HEAD~1"], else: ["HEAD"]
    else
      ["#{base_branch}...HEAD", "HEAD"]
    end
  end

  defp run_name_diff(revision, filter) do
    # `:(glob)` magic is required for `**` to span directories; a plain
    # `lib/**/*.ex` pathspec silently matches nothing for top-level files.
    case System.cmd(
           "git",
           [
             "diff",
             "--name-only",
             "--diff-filter=#{filter}",
             revision,
             "--",
             ":(glob)lib/**/*.ex"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  end

  # Read file and extract all defmodule names
  defp extract_modules_from_file(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> then(&Regex.scan(~r/defmodule\s+([\w.]+)/, &1))
      |> Enum.map(fn [_, module] -> module end)
    else
      []
    end
  end

  # Match the module cell exactly — a substring match would make a top-level
  # module like "Check" pull in every "Check.*" row.
  defp filter_coverage_lines(output, modules) do
    module_set = MapSet.new(modules)

    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      case Regex.run(~r/\|\s*([\w.]+)\s*\|/, line) do
        [_, module] -> MapSet.member?(module_set, module)
        _ -> false
      end
    end)
  end

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

    with {:ok, cached_hash} <- File.read(hash_file),
         true <- String.trim(cached_hash) == current_hash,
         {:ok, output} <- File.read(output_file) do
      {:ok, output}
    else
      _ -> :miss
    end
  end

  defp write_cache(hash, output) do
    File.mkdir_p!(".check")
    File.write!(@coverage_cache_path <> ".hash", hash)
    File.write!(@coverage_cache_path <> ".txt", output)
  end
end
