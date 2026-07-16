defmodule DripDrop.Channels.Email.OAuthToken do
  @moduledoc """
  Retrieves and caches host-owned OAuth access tokens for email providers.

  DripDrop never performs OAuth flows or stores refresh tokens. This module
  calls the adapter's `token_callback` and caches only the returned access token
  until its expiry.
  """

  alias DripDrop.Cache
  alias DripDrop.Channels.Helpers

  @max_ttl_ms :timer.hours(1)

  @doc """
  Returns a cached OAuth access token or refreshes one with the adapter callback.
  """
  @spec get(map(), atom()) :: {:ok, binary()} | {:error, term()}
  def get(adapter, provider) do
    cache_key = {__MODULE__, provider, adapter.id}

    case Cache.lookup(cache_key) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      _miss -> refresh(adapter, provider, cache_key)
    end
  end

  defp refresh(adapter, provider, cache_key) do
    callback = Helpers.credential(adapter, :token_callback)

    with {:ok, result} <- call_callback(callback, adapter),
         {:ok, token} <- access_token(result) do
      ttl = result |> ttl() |> min(@max_ttl_ms)
      if ttl > 0, do: Cache.put(cache_key, token, ttl: ttl)
      {:ok, token}
    else
      {:error, :revoked} -> {:error, {:token_callback, :revoked}}
      {:error, reason} -> {:error, {:token_callback, provider, reason}}
    end
  end

  defp call_callback(callback, adapter) when is_function(callback, 1), do: callback.(adapter)
  defp call_callback(callback, _adapter) when is_function(callback, 0), do: callback.()

  defp call_callback({module, function}, adapter),
    do: apply(module, function, [adapter])

  defp call_callback({module, function, args}, _adapter) when is_list(args),
    do: apply(module, function, args)

  defp call_callback(callback, _adapter), do: {:error, {:invalid_callback, callback}}

  defp access_token(%{access_token: token}) when is_binary(token), do: {:ok, token}
  defp access_token(%{"access_token" => token}) when is_binary(token), do: {:ok, token}
  defp access_token(%{token: token}) when is_binary(token), do: {:ok, token}
  defp access_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp access_token(token) when is_binary(token), do: {:ok, token}
  defp access_token(_result), do: {:error, :missing_access_token}

  defp ttl(%{expires_at: expires_at}), do: ttl_from_expires_at(expires_at)
  defp ttl(%{"expires_at" => expires_at}), do: ttl_from_expires_at(expires_at)
  defp ttl(%{expires_in: expires_in}), do: ttl_from_expires_in(expires_in)
  defp ttl(%{"expires_in" => expires_in}), do: ttl_from_expires_in(expires_in)
  defp ttl(_result), do: :timer.minutes(5)

  defp ttl_from_expires_at(%DateTime{} = expires_at) do
    expires_at
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> max(0)
  end

  defp ttl_from_expires_at(%NaiveDateTime{} = expires_at) do
    expires_at
    |> NaiveDateTime.diff(NaiveDateTime.utc_now(:second), :millisecond)
    |> max(0)
  end

  defp ttl_from_expires_at(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> ttl_from_expires_at(datetime)
      _invalid -> :timer.minutes(5)
    end
  end

  defp ttl_from_expires_at(_expires_at), do: :timer.minutes(5)

  defp ttl_from_expires_in(expires_in) when is_integer(expires_in) and expires_in > 0,
    do: :timer.seconds(expires_in)

  defp ttl_from_expires_in(expires_in) when is_binary(expires_in) do
    case Integer.parse(expires_in) do
      {expires_in, ""} when expires_in > 0 -> :timer.seconds(expires_in)
      _invalid -> :timer.minutes(5)
    end
  end

  defp ttl_from_expires_in(_expires_in), do: :timer.minutes(5)
end
