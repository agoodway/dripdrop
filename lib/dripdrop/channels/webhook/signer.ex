defmodule DripDrop.Channels.Webhook.Signer do
  @moduledoc """
  Signature signing and verification per the Standard Webhooks spec.

  This is a small re-implementation of the algorithm described at
  <https://www.standardwebhooks.com/>, mirroring the public surface of the
  upstream Elixir reference at
  <https://github.com/standard-webhooks/standard-webhooks/tree/main/libraries/elixir>.

  Vendored to remove a git-only dependency that blocked Hex publish.
  """

  import Plug.Conn

  @secret_prefix "whsec_"
  @signature_identifier "v1"
  @tolerance 5 * 60

  @doc """
  Signs a payload and returns a `v1,<base64-signature>` header value.

    * `id` — webhook message id (string)
    * `timestamp` — unix seconds (integer)
    * `payload` — map; JSON-encoded internally
    * `secret` — raw HMAC secret bytes, OR a base64 string, OR a `whsec_<base64>` string
  """
  @spec sign(String.t(), integer(), map(), binary()) :: String.t()
  def sign(id, _timestamp, _payload, _secret) when not is_binary(id),
    do: raise(ArgumentError, "Message id must be a string")

  def sign(_id, timestamp, _payload, _secret) when not is_integer(timestamp),
    do: raise(ArgumentError, "Message timestamp must be an integer")

  def sign(_id, _timestamp, payload, _secret) when not is_map(payload),
    do: raise(ArgumentError, "Message payload must be a map")

  def sign(_id, _timestamp, _payload, secret) when not is_binary(secret),
    do: raise(ArgumentError, "Secret must be a string")

  def sign(id, timestamp, payload, secret) do
    :ok = validate_timestamp(timestamp)

    key = decode_secret(secret)
    body = "#{id}.#{timestamp}.#{Jason.encode!(payload)}"
    mac = :crypto.mac(:hmac, :sha256, key, body) |> Base.encode64()

    "#{@signature_identifier},#{mac}"
  end

  @doc """
  Verifies a payload against the signatures present on `conn`.

  Reads `webhook-id`, `webhook-timestamp`, and `webhook-signature` headers and
  returns `true` when at least one signature matches. Raises `ArgumentError`
  when required headers are missing.
  """
  @spec verify(map(), Plug.Conn.t(), binary()) :: boolean()
  def verify(payload, %Plug.Conn{} = conn, secret) when is_map(payload) and is_binary(secret) do
    {id, timestamp_str, header_signatures} = required_headers(conn)
    timestamp = String.to_integer(timestamp_str)

    expected = sign(id, timestamp, payload, secret) |> strip_identifier()

    header_signatures
    |> Enum.map(&strip_identifier/1)
    |> Enum.any?(&Plug.Crypto.secure_compare(&1, expected))
  end

  @doc """
  Raises if `timestamp` is outside the 5-minute tolerance window. Returns `:ok`.
  """
  @spec validate_timestamp(integer()) :: :ok
  def validate_timestamp(timestamp) when is_integer(timestamp) do
    now = :os.system_time(:second)

    cond do
      timestamp > now + @tolerance -> raise ArgumentError, "Message timestamp too new"
      timestamp < now - @tolerance -> raise ArgumentError, "Message timestamp too old"
      true -> :ok
    end
  end

  defp decode_secret(@secret_prefix <> rest), do: Base.decode64!(rest)

  defp decode_secret(secret) do
    case Base.decode64(secret) do
      {:ok, bytes} -> bytes
      :error -> secret
    end
  end

  defp required_headers(conn) do
    with [id] when is_binary(id) <- get_req_header(conn, "webhook-id"),
         [ts] when is_binary(ts) <- get_req_header(conn, "webhook-timestamp"),
         sigs when is_list(sigs) and sigs != [] <- get_req_header(conn, "webhook-signature") do
      {id, ts, sigs}
    else
      _ -> raise ArgumentError, "Missing required headers"
    end
  end

  defp strip_identifier(signature),
    do: signature |> String.split(",") |> List.last()
end
