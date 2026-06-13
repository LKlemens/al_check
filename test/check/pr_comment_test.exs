defmodule Check.PRCommentTest do
  use ExUnit.Case, async: true

  alias Check.PRComment

  describe "format_delta/1" do
    test "positive delta gets + prefix and ✅" do
      assert PRComment.format_delta(2.5) == "+2.50% ✅"
    end

    test "zero delta is treated as positive" do
      assert PRComment.format_delta(0.0) == "+0.00% ✅"
    end

    test "negative delta gets ❌" do
      assert PRComment.format_delta(-1.0) == "-1.00% ❌"
    end
  end

  describe "table_row/3" do
    test "formats a row with positive delta" do
      assert PRComment.table_row("Check.Git", 85.71, 90.00) ==
               "| `Check.Git` | 85.71% | 90.00% | +4.29% ✅ |"
    end

    test "formats a row with negative delta" do
      assert PRComment.table_row("Check.Config", 92.0, 88.0) ==
               "| `Check.Config` | 92.00% | 88.00% | -4.00% ❌ |"
    end
  end

  describe "new_module_row/2" do
    test "shows N/A baseline and 🆕 new label" do
      assert PRComment.new_module_row("Check.PRComment", 75.0) ==
               "| `Check.PRComment` | N/A | 75.00% | 🆕 new |"
    end
  end

  # table_header/0 intentionally left untested to show partial coverage
end
