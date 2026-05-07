defmodule DripDrop.ShortLinks.Pipeline do
  @moduledoc """
  Rewrites payload URLs through the configured short-link provider.
  """

  alias DripDrop.ShortLink
  alias DripDrop.ShortLinks
  alias DripDrop.ShortLinks.Config
  alias DripDrop.ShortLinks.None
  alias DripDrop.ShortLinks.Request
  alias DripDrop.ShortLinks.Result

  @trailing_punctuation ~r/[.,\)\]\};:!?]+$/
  @rewrite_keys [:html, :text, :body]

  @type context :: %{
          optional(:step_execution_id) => Ecto.UUID.t() | binary(),
          optional(:tenant_key) => binary() | nil,
          optional(:sequence) => Ecto.Schema.t() | map(),
          optional(:step) => Ecto.Schema.t() | map(),
          optional(:provider_opts) => keyword(),
          optional(:tenant_short_links) => keyword()
        }

  @doc """
  Rewrites eligible URLs in a rendered payload through the configured provider.
  """
  @spec run(map(), context()) :: {:ok, map()} | {:error, map()}
  def run(payload, context \\ %{})

  def run(payload, context) when is_map(payload) do
    sequence = Map.get(context, :sequence)
    step = Map.get(context, :step)
    config = Config.resolve(sequence, step, Map.get(context, :tenant_short_links, []))

    if Keyword.get(config, :enabled, false) do
      rewrite_payload(payload, context, config)
    else
      {:ok, payload}
    end
  end

  def run(payload, _context), do: {:ok, payload}

  defp rewrite_payload(payload, context, config) do
    Enum.reduce_while(@rewrite_keys, {:ok, payload}, fn key, {:ok, acc} ->
      rewrite_payload_key(acc, key, context, config)
    end)
  end

  defp rewrite_payload_key(payload, key, context, config) do
    value = Map.get(payload, key) || Map.get(payload, to_string(key))

    if is_binary(value) do
      rewrite_payload_value(payload, key, value, context, config)
    else
      {:cont, {:ok, payload}}
    end
  end

  defp rewrite_payload_value(payload, key, value, context, config) do
    case rewrite_value(value, key, context, config) do
      {:ok, rewritten} -> {:cont, {:ok, Map.put(payload, key, rewritten)}}
      {:error, reason} -> handle_error(reason, payload, config)
    end
  end

  defp rewrite_value(html, :html, context, config), do: rewrite_html(html, context, config)
  defp rewrite_value(text, _key, context, config), do: rewrite_text(text, context, config)

  defp rewrite_html(html, context, config) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        with {:ok, rewritten} <- rewrite_nodes(document, context, config) do
          {:ok, Floki.raw_html(rewritten)}
        end

      {:error, reason} ->
        {:error, %{kind: :permanent, reason: {:html_parse, reason}}}
    end
  end

  defp rewrite_nodes(nodes, context, config) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case rewrite_node(node, context, config) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rewritten} -> {:ok, Enum.reverse(rewritten)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrite_node({tag, attrs, children}, _context, _config) when tag in ["script", "style"] do
    {:ok, {tag, attrs, children}}
  end

  defp rewrite_node({tag, attrs, children}, context, config) do
    with {:ok, attrs} <- rewrite_attrs(attrs, context, config),
         {:ok, children} <- rewrite_nodes(children, context, config) do
      {:ok, {tag, attrs, children}}
    end
  end

  defp rewrite_node(node, _context, _config), do: {:ok, node}

  defp rewrite_attrs(attrs, context, config) do
    attrs
    |> Enum.reduce_while({:ok, []}, fn
      {attr, url}, {:ok, acc} when attr in ["href", "src"] and is_binary(url) ->
        case resolve_url(url, context, config) do
          {:ok, rewritten} -> {:cont, {:ok, [{attr, rewritten} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      attr, {:ok, acc} ->
        {:cont, {:ok, [attr | acc]}}
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrite_text(text, context, config) do
    url_pattern = ~r/^https?:\/\/[^\s<>"']+$/i

    ~r/(https?:\/\/[^\s<>"']+)/i
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      if Regex.match?(url_pattern, part) do
        rewrite_text_url(part, context, config, acc)
      else
        {:cont, {:ok, [part | acc]}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrite_text_url(url, context, config, acc) do
    {url, suffix} = split_trailing_punctuation(url)

    case resolve_url(url, context, config) do
      {:ok, rewritten} -> {:cont, {:ok, [suffix, rewritten | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp split_trailing_punctuation(url) do
    suffix = Regex.run(@trailing_punctuation, url) |> List.wrap() |> List.first() || ""

    if suffix == "" do
      {url, suffix}
    else
      {String.trim_trailing(url, suffix), suffix}
    end
  end

  defp resolve_url(url, context, config) do
    with true <- eligible?(url, config),
         destination_url <- enrich_url(url, config),
         idempotency_key <- idempotency_key(url, destination_url, context, config),
         nil <- ShortLinks.get_by_idempotency_key(idempotency_key),
         {:ok, result} <-
           create_provider_link(url, destination_url, idempotency_key, context, config),
         :ok <- persist_result(url, destination_url, idempotency_key, result, context, config) do
      {:ok, result.short_url}
    else
      false -> {:ok, url}
      %ShortLink{short_url: short_url} when is_binary(short_url) -> {:ok, short_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp eligible?(url, config) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and
      not short_domain?(uri.host, config) and
      not excluded?(url, config)
  end

  defp short_domain?(host, config) do
    short_domains =
      [Keyword.get(config, :domain)]
      |> Enum.concat(List.wrap(Keyword.get(config, :domains, [])))
      |> Enum.reject(&is_nil/1)

    host in short_domains
  end

  defp excluded?(url, config) do
    Config.exclude_patterns(config)
    |> Enum.any?(fn
      %Regex{} = pattern -> Regex.match?(pattern, url)
      pattern when is_binary(pattern) -> String.contains?(url, pattern)
    end)
  end

  defp enrich_url(url, config) do
    utm =
      %{
        "utm_source" => Keyword.get(config, :utm_source),
        "utm_medium" => Keyword.get(config, :utm_medium),
        "utm_campaign" => Keyword.get(config, :utm_campaign),
        "utm_content" => Keyword.get(config, :utm_content)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    merge_query_params(url, utm)
  end

  defp merge_query_params(url, []), do: url

  defp merge_query_params(url, params) do
    uri = URI.parse(url)
    query = uri.query |> URI.decode_query() |> Map.merge(Map.new(params)) |> URI.encode_query()

    uri
    |> Map.put(:query, query)
    |> URI.to_string()
  end

  defp idempotency_key(original_url, destination_url, context, config) do
    provider = provider(config)
    provider_config = Keyword.drop(config, [:exclude_patterns])
    step_execution_id = Map.get(context, :step_execution_id, "no_execution")

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {step_execution_id, original_url, destination_url, provider, provider_config}
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp create_provider_link(original_url, destination_url, idempotency_key, context, config) do
    adapter = provider_module(config)
    request = request(original_url, destination_url, idempotency_key, context, config)
    opts = Keyword.merge(config, Map.get(context, :provider_opts, []))

    adapter.create_link(request, opts)
  end

  defp request(original_url, destination_url, idempotency_key, context, config) do
    step = Map.get(context, :step, %{})
    sequence = Map.get(context, :sequence, %{})

    %Request{
      original_url: original_url,
      destination_url: destination_url,
      idempotency_key: idempotency_key,
      tenant_key:
        Map.get(context, :tenant_key) || map_get(step, :tenant_key) ||
          map_get(sequence, :tenant_key),
      channel: map_get(step, :channel),
      sequence_key: map_get(sequence, :key),
      step_key: map_get(step, :key),
      domain: Keyword.get(config, :domain),
      key: Keyword.get(config, :key),
      prefix: Keyword.get(config, :prefix),
      metadata: Keyword.get(config, :metadata, %{}),
      utm: utm_config(config)
    }
  end

  defp persist_result(
         _url,
         _destination_url,
         _idempotency_key,
         %Result{response: %{skipped: true}},
         _context,
         _config
       ) do
    :ok
  end

  defp persist_result(original_url, destination_url, idempotency_key, result, context, config) do
    attrs = %{
      step_execution_id: Map.get(context, :step_execution_id),
      tenant_key: Map.get(context, :tenant_key),
      provider: provider(config),
      original_url: original_url,
      destination_url: destination_url,
      short_url: result.short_url,
      external_id: result.provider_id,
      idempotency_key: idempotency_key,
      metadata: result.response || %{}
    }

    ShortLinks.persist_result(attrs)
  end

  defp handle_error(reason, payload, config) do
    if Keyword.get(config, :on_error, :fail) == :send_originals do
      :telemetry.execute([:dripdrop, :short_link, :fallback], %{count: 1}, %{reason: reason})
      {:halt, {:ok, put_in(payload, [:short_links_fallback], true)}}
    else
      {:halt, {:error, reason}}
    end
  end

  defp provider_module(config), do: Keyword.get(config, :provider, None)

  defp provider(config),
    do: provider_module(config) |> Module.split() |> List.last() |> Macro.underscore()

  defp utm_config(config) do
    %{
      "source" => Keyword.get(config, :utm_source, "dripdrop"),
      "medium" => Keyword.get(config, :utm_medium),
      "campaign" => Keyword.get(config, :utm_campaign),
      "content" => Keyword.get(config, :utm_content)
    }
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_get(_map, _key), do: nil
end
