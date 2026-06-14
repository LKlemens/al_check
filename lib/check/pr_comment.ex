defmodule Check.PRComment do
  @moduledoc "Helpers for building PR comment markdown from coverage data."

  @doc """
  Formats a coverage delta as a markdown string with a status icon.

  ## Examples

      iex> Check.PRComment.format_delta(2.5)
      "+2.50% ✅"

      iex> Check.PRComment.format_delta(-1.0)
      "-1.00% ❌"

      iex> Check.PRComment.format_delta(0.0)
      "+0.00% ✅"
  """
  @spec format_delta(float()) :: String.t()
  def format_delta(delta) when delta >= 0,
    do: "+#{:erlang.float_to_binary(delta, decimals: 2)}% ✅"

  def format_delta(delta), do: "#{:erlang.float_to_binary(delta, decimals: 2)}% ❌"

  @doc """
  Builds a markdown table row for a single module's coverage comparison.

  ## Examples

      iex> Check.PRComment.table_row("Check.Git", 85.71, 90.00)
      "| `Check.Git` | 85.71% | 90.00% | +4.29% ✅ |"
  """
  @spec table_row(String.t(), float(), float()) :: String.t()
  def table_row(module, baseline, current) do
    delta = current - baseline
    "| `#{module}` | #{fmt(baseline)}% | #{fmt(current)}% | #{format_delta(delta)} |"
  end

  @doc """
  Builds a markdown table row for a newly added module (no baseline).

  ## Examples

      iex> Check.PRComment.new_module_row("Check.PRComment", 75.0)
      "| `Check.PRComment` | N/A | 75.00% | 🆕 new |"
  """
  @spec new_module_row(String.t(), float()) :: String.t()
  def new_module_row(module, current) do
    "| `#{module}` | N/A | #{fmt(current)}% | 🆕 new |"
  end

  # Intentionally uncovered — demonstrates ❌ drop on Check.Git when this file is modified
  @doc false
  @spec table_header() :: String.t()
  def table_header do
    "| Module | Baseline | Current | Delta |\n|--------|----------|---------|-------|"
  end

  defp fmt(pct), do: :erlang.float_to_binary(pct, decimals: 2)
end
