defmodule DripDrop.Channels.Webhook.Standard do
  @moduledoc """
  Builds Standard Webhooks request payloads and signature headers.
  """

  alias DripDrop.Channels.Helpers

  @doc """
  Returns Req options for sending a signed Standard Webhooks request.
  """
  @spec request_opts(atom(), binary(), map(), map(), map()) :: keyword()
  def request_opts(method, url, payload, headers, adapter) do
    webhook_id = Map.get(payload, :id) || Map.get(payload, :idempotency_key) || message_id()
    timestamp = :os.system_time(:second)
    secret = adapter |> Helpers.credential(:secret) |> normalize_secret()
    body = Jason.encode!(payload)

    signature = StandardWebhooks.sign(webhook_id, timestamp, payload, secret)

    [
      method: method,
      url: url,
      body: body,
      headers:
        headers
        |> normalize_headers()
        |> put_standard_header("content-type", "application/json")
        |> put_standard_header("webhook-id", webhook_id)
        |> put_standard_header("webhook-timestamp", Integer.to_string(timestamp))
        |> put_standard_header("webhook-signature", signature)
    ]
  end

  @doc """
  Normalizes a rendered webhook body into a Standard Webhooks event payload.
  """
  @spec payload(map(), term()) :: map()
  def payload(rendered_payload, body) when is_map(body) do
    body
    |> stringify_keys()
    |> Map.put_new("type", event_type(rendered_payload))
  end

  def payload(rendered_payload, body) do
    %{
      "type" => event_type(rendered_payload),
      "data" => body
    }
  end

  defp message_id do
    "msg_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp event_type(payload) do
    Map.get(payload, :type) || Map.get(payload, "type") || "dripdrop.webhook"
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers), do: headers
  defp normalize_headers(_headers), do: []

  defp put_standard_header(headers, key, value) do
    headers
    |> Enum.reject(fn {header, _value} -> String.downcase(to_string(header)) == key end)
    |> List.insert_at(-1, {key, value})
  end

  defp normalize_secret("whsec_" <> secret), do: secret
  defp normalize_secret(secret), do: secret
end
