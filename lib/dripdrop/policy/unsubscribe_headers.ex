defmodule DripDrop.Policy.UnsubscribeHeaders do
  @moduledoc """
  Adds RFC 8058 one-click unsubscribe headers when a step opts in.
  """

  @doc """
  Adds List-Unsubscribe headers to an email payload when the step opts in.
  """
  @spec apply(map(), map()) :: {:ok, map()} | {:error, map()}
  def apply(payload, context) when is_map(payload) and is_map(context) do
    if enabled?(context), do: add_headers(payload, context), else: {:ok, payload}
  end

  def apply(payload, _context), do: {:ok, payload}

  @doc """
  Returns whether an unsubscribe URL builder is configured.
  """
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(builder())

  defp add_headers(payload, context) do
    with {:ok, unsubscribe_url} <- unsubscribe_url(context) do
      headers =
        payload
        |> Map.get(:headers, %{})
        |> normalize_headers()
        |> Map.put("List-Unsubscribe", list_unsubscribe_value(unsubscribe_url))
        |> Map.put("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")

      {:ok, Map.put(payload, :headers, headers)}
    end
  end

  defp unsubscribe_url(context) do
    case builder() do
      nil ->
        {:error, %{kind: :permanent, reason: :unsubscribe_url_builder_unconfigured}}

      {module, function} ->
        apply_builder(module, function, [context])

      {module, function, extra_args} when is_list(extra_args) ->
        apply_builder(module, function, [context | extra_args])

      fun when is_function(fun, 1) ->
        normalize_builder_result(fun.(context))
    end
  rescue
    exception -> {:error, %{kind: :permanent, reason: {:unsubscribe_url_builder, exception}}}
  end

  defp apply_builder(module, function, args) do
    module
    |> apply(function, args)
    |> normalize_builder_result()
  end

  defp normalize_builder_result({:ok, url}) when is_binary(url), do: {:ok, url}
  defp normalize_builder_result(url) when is_binary(url), do: {:ok, url}

  defp normalize_builder_result({:error, reason}),
    do: {:error, %{kind: :permanent, reason: reason}}

  defp normalize_builder_result(result),
    do: {:error, %{kind: :permanent, reason: {:invalid_unsubscribe_url, result}}}

  defp list_unsubscribe_value(unsubscribe_url) do
    mailto =
      :dripdrop
      |> Application.get_env(:unsubscribe_mailto, "unsubscribe@example.com")
      |> then(&"mailto:#{&1}")

    "<#{unsubscribe_url}>, <#{mailto}>"
  end

  @doc """
  Returns whether unsubscribe headers are enabled for a dispatch context.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(%{step: %{channel: "email"} = step}) do
    config = step.config || %{}

    config_value(config, "unsubscribe_headers") == true ||
      config_value(config, "unsubscribe") == true ||
      get_in(config, ["email", "unsubscribe_headers"]) == true ||
      get_in(config, [:email, :unsubscribe_headers]) == true
  end

  def enabled?(_context), do: false

  defp config_value(config, key), do: DripDrop.Helpers.fetch_string_or_atom_key(config, key)

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_headers(headers) when is_list(headers), do: Map.new(headers)
  defp normalize_headers(_headers), do: %{}

  defp builder, do: Application.get_env(:dripdrop, :unsubscribe_url_builder)
end
