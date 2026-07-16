defmodule DripDrop.Web.WebhookPlug do
  @moduledoc """
  Framework-neutral Plug for provider webhook ingestion.

  This plug resolves the provider and adapter from the mounted path, verifies
  the provider signature, and leaves event normalization/persistence to the
  event-ingestion layer.
  """

  import Plug.Conn

  alias DripDrop.{ChannelAdapter, ChannelAdapters, Channels, Ingest}

  @doc """
  Initializes the webhook plug options.
  """
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Verifies and ingests a provider webhook request.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    with {:ok, provider_key, adapter_id} <- route(conn.path_info),
         %ChannelAdapter{} = adapter <- ChannelAdapters.get_active_adapter(adapter_id),
         {:ok, provider} <- Channels.provider_module(adapter.channel, adapter.provider),
         true <- provider_matches?(provider_key, adapter.provider),
         true <- webhook_supported?(provider, adapter),
         {:ok, conn, request} <- request(conn),
         :ok <- provider.verify_signature(adapter, request),
         :ok <- Ingest.ingest(adapter, request) do
      conn
      |> send_resp(202, "accepted")
      |> halt()
    else
      {:error, :body_too_large} ->
        emit_body_too_large(conn)

        conn
        |> send_resp(413, "request body too large")
        |> halt()

      {:error, :invalid_signature} ->
        emit_signature_failure(conn)

        conn
        |> send_resp(401, "invalid signature")
        |> halt()

      {:error, _reason} ->
        conn
        |> send_resp(401, "invalid signature")
        |> halt()

      _not_found ->
        conn
        |> send_resp(404, "not found")
        |> halt()
    end
  end

  defp route([provider, adapter_id | _rest]), do: {:ok, provider, adapter_id}
  defp route(_path_info), do: {:error, :not_found}

  defp provider_matches?(provider_key, provider) do
    normalize(provider_key) == normalize(provider)
  end

  defp webhook_supported?(provider, adapter), do: provider.webhook_routes(adapter) != []

  defp normalize(value) do
    value
    |> to_string()
    |> String.replace("_", "")
    |> String.replace("-", "")
    |> String.downcase()
  end

  defp request(conn) do
    with {:ok, raw_body, conn} <- fetch_raw_body(conn) do
      body_params = decode_body(raw_body, get_req_header(conn, "content-type"))
      request_params = if is_map(body_params), do: body_params, else: %{}

      {:ok, conn,
       %{
         headers: conn.req_headers,
         raw_body: raw_body,
         body: raw_body,
         body_params: body_params,
         params: Map.merge(conn.query_params, request_params),
         url: request_url(conn)
       }}
    end
  end

  # Hosts whose endpoint runs Plug.Parsers ahead of this plug (via a custom
  # body_reader) already consumed the request body before it reaches here, so
  # the raw bytes are read back from conn.assigns instead of the connection.
  # The assign holds iodata (a list of chunks), reassembled into a binary.
  defp fetch_raw_body(%Plug.Conn{assigns: %{raw_body: raw_body}} = conn)
       when not is_nil(raw_body) do
    {:ok, IO.iodata_to_binary(raw_body), conn}
  end

  defp fetch_raw_body(conn), do: read_full_body(conn)

  defp read_full_body(conn, acc \\ "") do
    max = max_body_bytes()
    read_opts = [length: max - byte_size(acc), read_length: 65_536]

    case read_body(conn, read_opts) do
      {:ok, body, conn} ->
        {:ok, acc <> body, conn}

      {:more, body, conn} ->
        next = acc <> body

        if byte_size(next) >= max do
          {:error, :body_too_large}
        else
          read_full_body(conn, next)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp max_body_bytes do
    Application.get_env(:dripdrop, :webhook_max_body_bytes) || 1_048_576
  end

  defp decode_body("", _content_type), do: %{}

  defp decode_body(body, [<<"application/json", _::binary>> | _rest]) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp decode_body(body, [<<"application/x-www-form-urlencoded", _::binary>> | _rest]),
    do: URI.decode_query(body)

  defp decode_body(_body, _content_type), do: %{}

  defp emit_signature_failure(conn) do
    :telemetry.execute([:dripdrop, :ingest, :signature_failure], %{count: 1}, %{
      provider: List.first(conn.path_info),
      adapter_id: Enum.at(conn.path_info, 1),
      request_id: get_resp_header(conn, "x-request-id") |> List.first()
    })
  end

  defp emit_body_too_large(conn) do
    :telemetry.execute([:dripdrop, :webhook, :body_too_large], %{count: 1}, %{
      provider: List.first(conn.path_info),
      adapter_id: Enum.at(conn.path_info, 1),
      max_bytes: max_body_bytes()
    })
  end
end
