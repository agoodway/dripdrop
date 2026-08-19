defmodule DripDrop.Cache do
  @moduledoc """
  Local Nebulex cache used for short-lived dispatch and provider state.
  """

  use Nebulex.Cache,
    otp_app: :dripdrop,
    adapter: Nebulex.Adapters.Local

  @doc """
  Fetches `key` using Nebulex 3's `{:ok, value}` / `{:error, reason}` contract.
  """
  @spec lookup(term()) :: {:ok, term()} | {:error, term()}
  def lookup(key), do: get(key)
end
