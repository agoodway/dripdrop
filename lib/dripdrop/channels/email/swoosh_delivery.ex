defmodule DripDrop.Channels.Email.SwooshDelivery do
  @moduledoc """
  Shared Swoosh delivery helper for built-in email providers.

  Provider modules use this helper to translate DripDrop email payloads into a
  `%Swoosh.Email{}` and to normalize Swoosh adapter responses into the channel
  delivery contract.
  """

  import Swoosh.Email

  alias DripDrop.Channels.{Helpers, Payload}
  alias Swoosh.Mailer

  @doc """
  Delivers a rendered email payload through a Swoosh mailer configuration.
  """
  @spec deliver(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def deliver(step, enrollment, adapter, config) do
    step
    |> Payload.get()
    |> email(enrollment, adapter)
    |> Mailer.deliver(config)
    |> provider_result()
  rescue
    exception -> {:error, %{kind: :temporary, reason: exception}}
  end

  @doc """
  Builds Swoosh adapter configuration from adapter credentials and config.
  """
  @spec config(map(), module(), [atom()]) :: keyword()
  def config(adapter, swoosh_adapter, keys) do
    credentials = adapter.credentials || %{}
    adapter_config = adapter.config || %{}

    keys
    |> Enum.reduce([adapter: swoosh_adapter], fn key, acc ->
      value = Helpers.credential(credentials, key) || config_value(adapter_config, key)
      if is_nil(value), do: acc, else: Keyword.put(acc, key, value)
    end)
    |> Keyword.merge(provider_options(adapter_config))
  end

  defp email(payload, enrollment, adapter) do
    new()
    |> from(mailbox(Map.get(payload, :from) || Helpers.credential(adapter, :from)))
    |> to(recipients(Map.get(payload, :to) || Helpers.recipient(enrollment, payload, :email)))
    |> put_optional(:reply_to, mailbox(Map.get(payload, :reply_to)))
    |> put_optional(:cc, recipients(Map.get(payload, :cc)))
    |> put_optional(:bcc, recipients(Map.get(payload, :bcc)))
    |> subject(Map.get(payload, :subject))
    |> text_body(Map.get(payload, :text))
    |> html_body(Map.get(payload, :html))
    |> put_headers(headers(payload))
    |> provider_options(Map.get(payload, :provider_options, %{}))
  end

  defp put_optional(email, _key, nil), do: email
  defp put_optional(email, :reply_to, value), do: reply_to(email, value)

  defp put_optional(email, :cc, values) do
    Enum.reduce(List.wrap(values), email, &cc(&2, &1))
  end

  defp put_optional(email, :bcc, values) do
    Enum.reduce(List.wrap(values), email, &bcc(&2, &1))
  end

  defp provider_options(email, options) when is_map(options) do
    Enum.reduce(options, email, fn {key, value}, acc ->
      put_provider_option(acc, normalize_option_key(key), value)
    end)
  end

  defp provider_options(email, _options), do: email

  defp put_headers(email, headers) do
    Enum.reduce(headers, email, fn {key, value}, acc -> header(acc, key, value) end)
  end

  defp normalize_option_key(key), do: DripDrop.Helpers.atom_or_string(key)

  defp mailbox(nil), do: nil
  defp mailbox({name, email}), do: {name, email}
  defp mailbox(%{"name" => name, "email" => email}), do: {name, email}
  defp mailbox(%{name: name, email: email}), do: {name, email}
  defp mailbox(email) when is_binary(email), do: email

  defp recipients(nil), do: []
  defp recipients(recipients) when is_list(recipients), do: Enum.map(recipients, &mailbox/1)
  defp recipients(recipient), do: [mailbox(recipient)]

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp headers(payload) do
    payload
    |> Map.get(:headers, %{})
    |> normalize_headers()
    |> maybe_put_idempotency_header(payload)
  end

  defp maybe_put_idempotency_header(headers, %{idempotency_key: key}) when is_binary(key),
    do: Map.put_new(headers, "X-DripDrop-Idempotency-Key", key)

  defp maybe_put_idempotency_header(headers, _payload), do: headers

  defp provider_result({:ok, result}) do
    {:ok, %{provider_message_id: provider_message_id(result), response: %{result: result}}}
  end

  defp provider_result({:error, reason}),
    do: {:error, %{kind: error_kind(reason), reason: reason}}

  defp provider_message_id(%{id: id}), do: id
  defp provider_message_id(%{"id" => id}), do: id
  defp provider_message_id(result) when is_binary(result), do: result
  defp provider_message_id(_result), do: nil

  defp error_kind({status, _body}) when status in 500..599 or status == 429, do: :temporary
  defp error_kind({status, _body}) when is_integer(status), do: :permanent
  defp error_kind(_reason), do: :temporary

  defp provider_options(%{"provider_options" => options}) when is_list(options), do: options
  defp provider_options(%{provider_options: options}) when is_list(options), do: options
  defp provider_options(_config), do: []

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end
end
