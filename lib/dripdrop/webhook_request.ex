defmodule DripDrop.WebhookRequest do
  @moduledoc """
  Normalizes provider webhook request access for signature verification.

  Providers receive either a Plug connection or a simple map from tests and
  from the framework-neutral webhook plug. This helper keeps header, body, URL,
  and parameter lookup consistent without coupling provider modules to Plug.
  """

  @doc """
  Fetches a request header by case-insensitive name.
  """
  @spec header(term(), binary()) :: binary() | nil
  def header(request, name) do
    normalized = String.downcase(name)

    request
    |> headers()
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == normalized, do: to_string(value)
    end)
  end

  @doc """
  Fetches a request parameter or nested parameter path.
  """
  @spec param(term(), binary() | [binary()]) :: term()
  def param(request, [key | rest]) do
    request
    |> param(key)
    |> nested(rest)
  end

  def param(request, key) do
    request
    |> params()
    |> get_key(key)
  end

  @doc """
  Returns merged request parameters from a Plug connection or request map.
  """
  @spec params(term()) :: map()
  def params(%Plug.Conn{} = conn), do: Map.merge(conn.query_params, conn.body_params)
  def params(%{params: params}) when is_map(params), do: params
  def params(%{"params" => params}) when is_map(params), do: params
  def params(%{form: params}) when is_map(params), do: params
  def params(%{"form" => params}) when is_map(params), do: params
  def params(%{body_params: params}) when is_map(params), do: params
  def params(%{"body_params" => params}) when is_map(params), do: params
  def params(request) when is_map(request), do: request
  def params(_request), do: %{}

  @doc """
  Returns the raw request body used for signature verification.
  """
  @spec body(term()) :: binary()
  def body(%{raw_body: body}) when is_binary(body), do: body
  def body(%{"raw_body" => body}) when is_binary(body), do: body
  def body(%Plug.Conn{assigns: %{raw_body: body}}) when is_binary(body), do: body
  def body(%Plug.Conn{body_params: params}), do: Jason.encode!(params)
  def body(%{body: body}) when is_binary(body), do: body
  def body(%{"body" => body}) when is_binary(body), do: body
  def body(%{body_params: params}), do: Jason.encode!(params)
  def body(%{"body_params" => params}), do: Jason.encode!(params)
  def body(_request), do: ""

  @doc """
  Returns the absolute request URL when available.
  """
  @spec url(term()) :: binary() | nil
  def url(%{url: url}), do: url
  def url(%{"url" => url}), do: url
  def url(%Plug.Conn{} = conn), do: Plug.Conn.request_url(conn)
  def url(_request), do: nil

  defp headers(%Plug.Conn{} = conn), do: conn.req_headers
  defp headers(%{headers: headers}), do: normalize_headers(headers)
  defp headers(%{"headers" => headers}), do: normalize_headers(headers)
  defp headers(_request), do: []

  defp normalize_headers(headers) when is_map(headers), do: Map.to_list(headers)
  defp normalize_headers(headers) when is_list(headers), do: headers
  defp normalize_headers(_headers), do: []

  defp get_key(map, key), do: DripDrop.Helpers.fetch_string_or_atom_key(map, key)

  defp nested(value, []), do: value

  defp nested(value, [key | rest]) when is_map(value) do
    value
    |> get_key(key)
    |> nested(rest)
  end

  defp nested(_value, _path), do: nil
end
