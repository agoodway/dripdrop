defmodule DripDrop.Cache do
  @moduledoc """
  Local Nebulex cache used for short-lived dispatch and provider state.
  """

  use Nebulex.Cache,
    otp_app: :dripdrop,
    adapter: Nebulex.Adapters.Local

  Application.load(:nebulex)

  @doc """
  Fetches `key`, normalizing the result to `{:ok, value}` / `{:error, reason}`.

  Nebulex 3 returns those tuples already; Nebulex 2 returns the bare value (nil
  on miss) and raises on errors. Going through this function lets callers behave
  the same on either major version, and the branch is resolved at compile time
  so neither pays for the check.
  """
  @spec lookup(term()) :: {:ok, term()} | {:error, term()}
  if Version.match?(to_string(Application.spec(:nebulex, :vsn)), ">= 3.0.0") do
    def lookup(key), do: get(key)
  else
    def lookup(key) do
      {:ok, get(key)}
    rescue
      error -> {:error, error}
    end
  end
end
