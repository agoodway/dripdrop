defmodule DripDrop.Policy.BounceComplaintThresholds do
  @moduledoc """
  Periodically pauses adapters whose rolling bounce or complaint rates cross policy limits.
  """

  use GenServer

  require Logger

  alias DripDrop.{AdapterHealth, ChannelAdapter, Clock, DBHelpers, Repo}

  @schema Application.compile_env(:dripdrop, :schema, "dripdrop")
  @default_interval_ms 60_000
  @default_window_days 30
  @default_complaint_rate 0.003
  @default_bounce_rate 0.02
  @default_pause_seconds 86_400

  @doc """
  Starts the periodic bounce and complaint threshold checker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs one threshold check and pauses any adapters that exceed limits.
  """
  @spec check_all() :: {:ok, non_neg_integer()} | {:error, term()}
  def check_all do
    with {:ok, rows} <- threshold_rows(config()),
         {:ok, paused_count} <- pause_threshold_adapters(rows),
         {:ok, _probe_count} <- AdapterHealth.evaluate_probes() do
      {:ok, paused_count}
    end
  end

  defp pause_threshold_adapters(rows) do
    rows
    |> Enum.reduce_while({:ok, 0}, &pause_adapter/2)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    }

    schedule_check(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:check_thresholds, state) do
    case check_all() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.error("[dripdrop] BounceComplaintThresholds.check_all failed: #{inspect(reason)}")

        :telemetry.execute(
          [:dripdrop, :policy, :bounce_complaint_check, :error],
          %{count: 1},
          %{reason: reason}
        )
    end

    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  defp schedule_check(interval_ms), do: Process.send_after(self(), :check_thresholds, interval_ms)

  defp threshold_rows(config) do
    schema = @schema

    sql = """
    WITH events AS (
      SELECT
        coalesce(
          message_events.event_data->>'adapter_id',
          step_executions.metadata->>'adapter_id',
          step_executions.metadata->>'rate_limit_adapter_id'
        )::uuid AS adapter_id,
        message_events.event_type
      FROM #{schema}.message_events
      LEFT JOIN #{schema}.step_executions
        ON step_executions.id = message_events.step_execution_id
      WHERE message_events.occurred_at >= now() - make_interval(days => $1::int)
    ),
    stats AS (
      SELECT
        adapter_id,
        count(*) FILTER (WHERE event_type = 'sent')::int AS sent_count,
        count(*) FILTER (WHERE event_type = 'bounced')::int AS bounce_count,
        count(*) FILTER (WHERE event_type = 'complained')::int AS complaint_count
      FROM events
      WHERE adapter_id IS NOT NULL
      GROUP BY adapter_id
    )
    SELECT
      adapter_id,
      sent_count,
      bounce_count,
      complaint_count,
      CASE WHEN sent_count = 0 THEN 0 ELSE bounce_count::float / sent_count END AS bounce_rate,
      CASE WHEN sent_count = 0 THEN 0 ELSE complaint_count::float / sent_count END AS complaint_rate
    FROM stats
    WHERE sent_count > 0
      AND (
        bounce_count::float / sent_count >= $2::float
        OR complaint_count::float / sent_count >= $3::float
      )
    """

    params = [
      config.window_days,
      config.bounce_rate,
      config.complaint_rate
    ]

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_stats/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_to_stats([
         adapter_id,
         sent_count,
         bounce_count,
         complaint_count,
         bounce_rate,
         complaint_rate
       ]) do
    %{
      adapter_id: DBHelpers.load_uuid(adapter_id),
      sent_count: sent_count,
      bounce_count: bounce_count,
      complaint_count: complaint_count,
      bounce_rate: bounce_rate,
      complaint_rate: complaint_rate
    }
  end

  defp pause_adapter(stats, {:ok, count}) do
    case Repo.get(ChannelAdapter, stats.adapter_id) do
      nil ->
        {:cont, {:ok, count}}

      %ChannelAdapter{} = adapter ->
        case update_paused_until(adapter, stats) do
          {:ok, _adapter} ->
            emit_thresholds(stats, adapter)
            {:cont, {:ok, count + 1}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end
  end

  defp update_paused_until(adapter, stats) do
    paused_until = Clock.seconds_from_now(config(:pause_seconds, @default_pause_seconds))

    reason = paused_reason(stats)

    AdapterHealth.transition(adapter, :resting,
      manual: true,
      reason: reason,
      resting_until: paused_until,
      config_merge: %{
        "paused_until" => DateTime.to_iso8601(paused_until),
        "paused_reason" => reason
      }
    )
    |> case do
      {:ok, updated, _events} -> {:ok, updated}
      other -> other
    end
  end

  defp paused_reason(%{complaint_rate: complaint_rate}) do
    if complaint_rate >= config(:complaint_rate, @default_complaint_rate) do
      "complaint_threshold"
    else
      "bounce_threshold"
    end
  end

  defp paused_reason(_stats), do: "bounce_threshold"

  defp emit_thresholds(stats, adapter) do
    if stats.complaint_rate >= config(:complaint_rate, @default_complaint_rate) do
      :telemetry.execute(
        [:dripdrop, :policy, :complaint_threshold],
        %{rate: stats.complaint_rate},
        %{
          adapter_id: stats.adapter_id,
          tenant_key: adapter.tenant_key,
          provider: adapter.provider,
          sent_count: stats.sent_count,
          complaint_count: stats.complaint_count
        }
      )
    end

    if stats.bounce_rate >= config(:bounce_rate, @default_bounce_rate) do
      :telemetry.execute([:dripdrop, :policy, :bounce_threshold], %{rate: stats.bounce_rate}, %{
        adapter_id: stats.adapter_id,
        tenant_key: adapter.tenant_key,
        provider: adapter.provider,
        sent_count: stats.sent_count,
        bounce_count: stats.bounce_count
      })
    end
  end

  defp config do
    %{
      window_days: config(:window_days, @default_window_days),
      bounce_rate: config(:bounce_rate, @default_bounce_rate),
      complaint_rate: config(:complaint_rate, @default_complaint_rate)
    }
  end

  defp config(key, default) do
    :dripdrop
    |> Application.get_env(:bounce_complaint_thresholds, [])
    |> config_value(key, default)
  end

  defp config_value(config, key, default) when is_map(config),
    do: Map.get(config, to_string(key), Map.get(config, key, default))

  defp config_value(config, key, default) when is_list(config),
    do: config |> Map.new() |> config_value(key, default)

  defp config_value(_config, _key, default), do: default
end
