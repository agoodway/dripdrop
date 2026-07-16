defmodule DripDrop.Cache do
  @moduledoc """
  Local Nebulex cache used for short-lived dispatch and provider state.
  """

  use Nebulex.Cache,
    otp_app: :dripdrop,
    adapter: Nebulex.Adapters.Local

  Application.load(:nebulex)

  # Nebulex 3 `get/1` returns `{:ok, value}` / `{:error, reason}` tuples while
  # Nebulex 2 returns the bare value (nil on miss) and raises on errors.
  # `lookup/1` normalizes to the tuple shape so callers behave the same on
  # either major version.
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
