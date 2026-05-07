defmodule DripDrop.HookBehavior do
  @moduledoc """
  Behaviour for host-defined Elixir hooks invoked during dispatch.
  """

  @callback handle_hook(atom(), term(), map()) :: {:ok, term()} | {:error, term()}
end
