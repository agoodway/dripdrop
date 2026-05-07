defmodule DripDrop.DataCase do
  @moduledoc """
  Test case for tests that need DripDrop database access.

  The test suite uses the same Docker database as development and isolates each
  test through `Ecto.Adapters.SQL.Sandbox`, matching the GoodSupport pattern.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias DripDrop.TestRepo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DripDrop.DataCase
    end
  end

  setup tags do
    DripDrop.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Starts a sandbox owner for the current test.
  """
  @spec setup_sandbox(map()) :: :ok
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(DripDrop.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Converts changeset errors into a map of human-readable messages.
  """
  @spec errors_on(Ecto.Changeset.t()) :: map()
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
