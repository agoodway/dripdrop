defmodule DripDrop.Jobs.CronTickTest do
  use ExUnit.Case, async: true

  alias DripDrop.Jobs.CronTick

  test "is compiled as a PgFlow job" do
    assert {:module, CronTick} = Code.ensure_loaded(CronTick)
    assert function_exported?(CronTick, :__pgflow_definition__, 0)
    assert function_exported?(CronTick, :__pgflow_handler__, 1)
    assert function_exported?(CronTick, :perform, 2)
  end
end
