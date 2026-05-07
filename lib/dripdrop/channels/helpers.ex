defmodule DripDrop.Channels.Helpers do
  @moduledoc """
  Shared helpers for provider implementations.
  """

  alias Plug.Crypto

  @doc """
  Reads a credential from either an adapter or credential map.
  """
  @spec credential(map(), atom() | binary(), term()) :: term()
  def credential(adapter, key, default \\ nil)

  def credential(%{credentials: credentials}, key, default) do
    fetch_key(credentials || %{}, key, default)
  end

  def credential(credentials, key, default) when is_map(credentials) do
    fetch_key(credentials, key, default)
  end

  @doc """
  Removes keys whose values are `nil`.
  """
  @spec drop_nil_values(map()) :: map()
  def drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @doc """
  Resolves the recipient for a channel from payload overrides or enrollment data.
  """
  @spec recipient(term(), map(), binary() | atom()) :: binary() | nil
  def recipient(enrollment, payload, channel) do
    Map.get(payload, :to) ||
      Map.get(payload, "to") ||
      get_in(enrollment_data(enrollment), [to_string(channel)])
  end

  @doc """
  Normalizes an HTTP provider response into the channel delivery contract.
  """
  @spec provider_result(
          {:ok, %{status: integer(), body: term()}} | {:error, term()},
          atom(),
          (term() -> binary() | nil)
        ) ::
          {:ok, map()} | {:error, map()}
  def provider_result({:ok, %{status: status, body: body}}, _provider, message_id_fun)
      when status in 200..299 do
    {:ok, %{provider_message_id: message_id_fun.(body), response: %{status: status, body: body}}}
  end

  def provider_result({:ok, %{status: status, body: body}}, provider, _message_id_fun)
      when status in 500..599 or status == 429 do
    {:error, %{kind: :temporary, reason: {provider, status, body}}}
  end

  def provider_result({:ok, %{status: status, body: body}}, provider, _message_id_fun) do
    {:error, %{kind: :permanent, reason: {provider, status, body}}}
  end

  def provider_result({:error, reason}, _provider, _message_id_fun) do
    {:error, %{kind: :temporary, reason: reason}}
  end

  @doc """
  Returns configured `Req` options for channel provider HTTP calls.

  Tests and host applications can provide options globally through
  `config :dripdrop, :channel_req_options` or per adapter through
  `adapter.config["req_options"]`.
  """
  @spec request_options(map()) :: keyword()
  def request_options(adapter) do
    adapter_options =
      adapter
      |> adapter_config()
      |> fetch_key(:req_options, [])

    :dripdrop
    |> Application.get_env(:channel_req_options, [])
    |> Keyword.merge(List.wrap(adapter_options))
  end

  @doc """
  Constant-time comparison of two binaries that also guards size mismatch.

  `Plug.Crypto.secure_compare/2` requires equal byte sizes; this wrapper folds
  the size check into the comparison so callers can compare a candidate
  signature directly without leaking length information.
  """
  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Crypto.secure_compare(left, right)
  end

  def secure_compare(_left, _right), do: false

  @doc """
  Verifies an HMAC-SHA256 hex signature against a key + payload pair.
  """
  @spec hmac_sha256_verify(binary(), iodata(), binary()) :: boolean()
  def hmac_sha256_verify(key, payload, signature_hex)
      when is_binary(key) and is_binary(signature_hex) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, key, payload)
      |> Base.encode16(case: :lower)

    secure_compare(expected, String.downcase(signature_hex))
  end

  def hmac_sha256_verify(_key, _payload, _signature), do: false

  @doc """
  Returns true when `timestamp` is within `max_seconds` of `reference` (default `now`).

  Accepts unix timestamps as integer or string and ISO 8601 strings. Used to
  reject replayed webhook deliveries.
  """
  @spec within_skew?(term(), pos_integer(), DateTime.t() | nil) :: boolean()
  def within_skew?(timestamp, max_seconds, reference \\ nil) do
    reference = reference || DateTime.utc_now()

    case parse_timestamp(timestamp) do
      {:ok, %DateTime{} = ts} -> abs(DateTime.diff(reference, ts, :second)) <= max_seconds
      :error -> false
    end
  end

  defp parse_timestamp(timestamp) when is_integer(timestamp),
    do: DateTime.from_unix(timestamp, :second)

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {seconds, ""} ->
        DateTime.from_unix(seconds, :second)

      _other ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _error -> :error
        end
    end
  end

  defp parse_timestamp(_other), do: :error

  defp fetch_key(map, key, default) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp fetch_key(map, key, default) when is_binary(key) do
    case DripDrop.Helpers.atom_or_string(key) do
      atom_key when is_atom(atom_key) -> Map.get(map, key) || Map.get(map, atom_key, default)
      _binary -> Map.get(map, key, default)
    end
  end

  defp adapter_config(%{config: config}) when is_map(config), do: config
  defp adapter_config(_adapter), do: %{}

  defp enrollment_data(%{data: data}) when is_map(data), do: data
  defp enrollment_data(_enrollment), do: %{}
end
