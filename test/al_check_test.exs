defmodule AlCheckTest do
  use ExUnit.Case

  test "version is set" do
    assert is_binary(Mix.Project.config()[:version])
  end
end
