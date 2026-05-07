defmodule DripDrop.Templates.Validators do
  @moduledoc """
  Channel-specific rendered payload validators.
  """

  @doc """
  Validates a rendered payload for the given channel and variable scope.
  """
  @spec validate(map() | binary(), atom() | binary(), map()) :: {:ok, map()} | {:error, map()}
  def validate(rendered, channel, vars) do
    channel
    |> normalize_channel()
    |> validate_channel(rendered, vars)
  end

  defp validate_channel(:email, rendered, _vars) do
    payload = atomize_known_keys(rendered)
    subject = Map.get(payload, :subject)
    text = Map.get(payload, :text)
    html = Map.get(payload, :html)

    cond do
      blank?(subject) ->
        error(:missing_subject)

      blank?(text) and blank?(html) ->
        error(:empty_body)

      true ->
        {:ok, Map.put_new(payload, :headers, %{})}
    end
  end

  defp validate_channel(:sms, rendered, vars) do
    payload = rendered |> body_payload() |> Map.put_new(:media_urls, [])
    max_chars = get_in(vars, ["config", "sms_max_chars"]) || vars[:sms_max_chars] || 1_600

    cond do
      blank?(payload.body) -> error(:empty_body)
      String.length(payload.body) > max_chars -> error(:sms_too_long)
      true -> {:ok, payload}
    end
  end

  defp validate_channel(:webhook, rendered, _vars) do
    payload = atomize_known_keys(rendered)

    if blank?(Map.get(payload, :url)) do
      error(:missing_url)
    else
      {:ok, Map.put_new(payload, :method, :post)}
    end
  end

  defp validate_channel(:pubsub, rendered, _vars) do
    payload = atomize_known_keys(rendered)

    cond do
      blank?(Map.get(payload, :topic)) -> error(:missing_topic)
      blank?(Map.get(payload, :event)) -> error(:missing_event)
      true -> {:ok, payload}
    end
  end

  defp validate_channel(:slack, rendered, _vars) do
    payload = rendered |> body_payload(:text) |> Map.put_new(:blocks, nil)

    if blank?(payload.text), do: error(:empty_body), else: {:ok, payload}
  end

  defp validate_channel(:telegram, rendered, _vars) do
    payload = rendered |> body_payload(:text) |> atomize_known_keys()

    cond do
      blank?(Map.get(payload, :chat_id)) -> error(:missing_chat_id)
      blank?(Map.get(payload, :text)) -> error(:empty_body)
      true -> {:ok, payload}
    end
  end

  defp validate_channel(:whatsapp, rendered, _vars) do
    payload = rendered |> body_payload(:text) |> atomize_known_keys()

    cond do
      blank?(Map.get(payload, :to)) ->
        error(:missing_recipient)

      blank?(Map.get(payload, :text)) and blank?(Map.get(payload, :template)) ->
        error(:empty_body)

      true ->
        {:ok, payload}
    end
  end

  defp validate_channel(_channel, rendered, _vars), do: {:ok, atomize_known_keys(rendered)}

  defp body_payload(body, key \\ :body)
  defp body_payload(body, key) when is_binary(body), do: %{key => body}
  defp body_payload(body, _key) when is_map(body), do: atomize_known_keys(body)

  defp atomize_known_keys(rendered) when is_map(rendered) do
    Map.new(rendered, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp atomize_known_keys(rendered), do: %{body: rendered}

  defp normalize_key(key), do: DripDrop.Helpers.atom_or_string(key)

  defp normalize_channel(channel) when is_atom(channel), do: channel
  defp normalize_channel(channel) when is_binary(channel), do: String.to_existing_atom(channel)
  defp normalize_channel(channel), do: channel

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?([]), do: true
  defp blank?(_value), do: false

  defp error(reason), do: {:error, %{kind: :permanent, reason: reason}}
end
