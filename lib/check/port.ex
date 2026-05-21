defmodule CheckEscript.Port do
  @moduledoc "Wrapper around Port.open for mockability in tests."

  def open(cmd, args) do
    Port.open({:spawn_executable, System.find_executable(cmd)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])
  end
end
