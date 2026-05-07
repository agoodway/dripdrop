defmodule DripDrop.Dispatch.Concurrency do
  @moduledoc """
  Limits in-flight dispatches by channel and adapter.

  The gate is intentionally database-backed so all worker runtimes see the same
  concurrency counts. Advisory transaction locks serialize cap checks per scope,
  and hits defer the execution instead of failing it.
  """

  alias DripDrop.{Clock, DBHelpers, Repo}

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")
  @default_defer_seconds 30

  @doc """
  Checks configured concurrency caps for the dispatch context and adapter.
  """
  @spec check(map(), map()) :: :ok | {:defer, DateTime.t(), map()} | {:error, term()}
  def check(context, adapter) do
    context
    |> scopes(adapter)
    |> Enum.reduce_while(:ok, &check_scope(&1, &2, context, adapter))
  end

  defp check_scope(_scope, {:defer, _defer_until, _metadata} = defer, _context, _adapter),
    do: {:halt, defer}

  defp check_scope(scope, :ok, context, adapter) do
    case count_inflight(scope, context, adapter) do
      {:ok, count} when count < scope.cap ->
        {:cont, :ok}

      {:ok, count} ->
        defer_until = Clock.seconds_from_now(defer_seconds())
        emit_hit(scope, context, adapter, count, defer_until)

        {:halt,
         {:defer, defer_until,
          %{
            reason: "concurrency_cap",
            scope: scope.name,
            cap: scope.cap,
            in_flight: count
          }}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp scopes(context, adapter) do
    [
      scope(:channel, adapter.channel, channel_cap(adapter.channel, context.step)),
      scope(:adapter, adapter.id, adapter_cap(adapter, context.step))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp scope(_name, _key, nil), do: nil
  defp scope(_name, _key, cap) when cap <= 0, do: nil
  defp scope(name, key, cap), do: %{name: name, key: key, cap: cap}

  defp count_inflight(scope, context, adapter) do
    schema = @schema
    {filter, params} = filter(scope, context, adapter)

    sql = """
    WITH locked AS (
      SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))
    ),
    marked AS (
      UPDATE #{schema}.step_executions
      SET metadata = coalesce(metadata, '{}'::jsonb) || $2::jsonb,
          updated_at = now()
      FROM locked
      WHERE id = $3::uuid
      RETURNING id
    )
    SELECT count(*)::int
    FROM #{schema}.step_executions
    WHERE state IN ('claiming', 'sending')
      AND id != $3::uuid
      AND (($4::text IS NULL AND tenant_key IS NULL) OR tenant_key = $4::text)
      #{filter}
    """

    base_params = [
      "dripdrop:concurrency:#{scope.name}:#{scope.key}",
      %{adapter_id: adapter.id},
      DBHelpers.dump_uuid(context.execution.id),
      context.execution.tenant_key
    ]

    case Repo.query(sql, base_params ++ params) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter(%{name: :channel}, _context, adapter),
    do: {"AND channel = $5::text", [adapter.channel]}

  defp filter(%{name: :adapter}, _context, adapter),
    do: {"AND metadata->>'adapter_id' = $5::text", [adapter.id]}

  defp channel_cap(channel, step) do
    step_cap(step, ["concurrency", "channel"]) ||
      config_cap([:channel, channel])
  end

  defp adapter_cap(adapter, step) do
    step_cap(step, ["concurrency", "adapter"]) ||
      config_cap([:adapter, adapter.id]) ||
      config_cap([:adapter, adapter.name])
  end

  defp step_cap(%{config: config}, path) when is_map(config), do: get_in(config, path)
  defp step_cap(_step, _path), do: nil

  defp config_cap(path) do
    :dripdrop
    |> Application.get_env(:dispatch_concurrency, [])
    |> get_config_path(path)
    |> parse_cap()
  end

  defp get_config_path(config, path) when is_list(config),
    do: config |> Map.new() |> get_config_path(path)

  defp get_config_path(config, path) when is_map(config),
    do: Enum.reduce(path, config, &config_key/2)

  defp get_config_path(_config, _path), do: nil

  defp config_key(key, config) when is_map(config) do
    Map.get(config, key) || Map.get(config, to_string(key)) || Map.get(config, to_atom(key))
  end

  defp config_key(_key, _config), do: nil

  defp to_atom(key) when is_atom(key), do: key

  defp to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp parse_cap(cap) when is_integer(cap), do: cap

  defp parse_cap(cap) when is_binary(cap) do
    case Integer.parse(cap) do
      {cap, ""} -> cap
      _invalid -> nil
    end
  end

  defp parse_cap(_cap), do: nil

  defp defer_seconds do
    :dripdrop
    |> Application.get_env(:dispatch_concurrency, [])
    |> get_config_path([:defer_seconds])
    |> parse_cap()
    |> Kernel.||(@default_defer_seconds)
  end

  defp emit_hit(scope, context, adapter, count, defer_until) do
    :telemetry.execute([:dripdrop, :dispatch, :concurrency_limited], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      channel: adapter.channel,
      adapter_id: adapter.id,
      scope: scope.name,
      cap: scope.cap,
      in_flight: count,
      defer_until: defer_until
    })
  end
end
