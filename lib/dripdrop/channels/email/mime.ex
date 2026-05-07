defmodule DripDrop.Channels.Email.MIME do
  @moduledoc """
  Builds simple RFC 5322 messages for direct email APIs.

  Gmail requires a base64url-encoded raw message; this module centralizes the
  header and body formatting used by that provider.
  """

  @doc """
  Builds an RFC 5322 email message from a rendered payload.
  """
  @spec rfc5322(map(), map(), map()) :: binary()
  def rfc5322(payload, enrollment, adapter) do
    headers(payload, enrollment, adapter)
    |> Enum.map_join("\r\n", fn {key, value} -> "#{key}: #{sanitize(value)}" end)
    |> Kernel.<>("\r\n\r\n")
    |> Kernel.<>(body(payload))
  end

  defp headers(payload, enrollment, adapter) do
    base = [
      {"From", Map.get(payload, :from) || credential(adapter, :user_email)},
      {"To", recipients(Map.get(payload, :to) || recipient(enrollment))},
      {"Subject", Map.get(payload, :subject)},
      {"MIME-Version", "1.0"},
      {"Content-Type", content_type(payload)}
    ]

    payload
    |> headers_map()
    |> Enum.reduce(base, fn {key, value}, acc -> [{key, value} | acc] end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.reverse()
  end

  defp body(%{html: html}) when is_binary(html), do: html
  defp body(%{text: text}) when is_binary(text), do: text
  defp body(_payload), do: ""

  defp content_type(%{html: html}) when is_binary(html), do: ~s(text/html; charset="UTF-8")
  defp content_type(_payload), do: ~s(text/plain; charset="UTF-8")

  defp recipients(recipients) when is_list(recipients),
    do: Enum.map_join(recipients, ", ", &mailbox/1)

  defp recipients(recipient), do: mailbox(recipient)

  defp mailbox({name, email}), do: "#{name} <#{email}>"
  defp mailbox(%{"name" => name, "email" => email}), do: "#{name} <#{email}>"
  defp mailbox(%{name: name, email: email}), do: "#{name} <#{email}>"
  defp mailbox(email), do: to_string(email)

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  defp headers_map(payload) do
    payload
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> maybe_put_idempotency_header(payload)
  end

  defp maybe_put_idempotency_header(headers, %{idempotency_key: key}) when is_binary(key),
    do: [{"X-DripDrop-Idempotency-Key", key} | headers]

  defp maybe_put_idempotency_header(headers, _payload), do: headers

  defp credential(%{credentials: credentials}, key) do
    Map.get(credentials || %{}, key) || Map.get(credentials || %{}, to_string(key))
  end

  defp recipient(%{data: data}) when is_map(data),
    do: Map.get(data, "email") || Map.get(data, :email)

  defp recipient(_enrollment), do: nil

  defp sanitize(value) do
    value
    |> to_string()
    |> String.replace(["\r", "\n"], "")
  end
end
