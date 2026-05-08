defmodule DripDrop.AdapterHealth do
  @moduledoc """
  Health-state transitions and ramp-cap math for outbound adapters.
  """

  import Ecto.Query

  alias DripDrop.{ChannelAdapter, Clock, Repo}
  alias DripDrop.MessageEvent

  @one_day 86_400
  @default_bounce_rate 0.02
  @default_complaint_rate 0.003
  @default_probe_min_sends 5
  @default_probe_backoff_seconds 86_400
  @max_probe_backoff_seconds 7 * @one_day
  @allowed_transitions %{
    nil => [:active, :ramping],
    active: [:resting, nil],
    ramping: [:active, :resting],
    resting: [:probing],
    probing: [:ramping, :resting]
  }

  @doc """
  Transitions an adapter to a new health state.
  """
  @spec transition(Ecto.Schema.t(), atom() | nil, keyword() | map()) ::
          {:ok, Ecto.Schema.t(), [:state_changed_event]} | {:error, :invalid_transition}
  def transition(%ChannelAdapter{} = adapter, new_state, opts \\ []) do
    opts = Map.new(opts)

    if manual?(opts) or allowed_transition?(adapter.health_state, new_state) do
      do_transition(adapter, new_state, opts)
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Computes today's effective cap for an adapter.
  """
  @spec effective_cap_today(Ecto.Schema.t()) :: integer() | nil
  def effective_cap_today(%ChannelAdapter{health_state: :probing}) do
    outbound_default(:probe_daily_cap, 5)
  end

  def effective_cap_today(%ChannelAdapter{daily_cap: nil}), do: nil

  def effective_cap_today(%ChannelAdapter{
        daily_cap: daily_cap,
        ramp_started_at: %DateTime{} = ramp_started_at,
        ramp_increment: ramp_increment,
        ramp_floor: ramp_floor
      })
      when is_integer(daily_cap) and is_integer(ramp_increment) and is_integer(ramp_floor) do
    days_elapsed =
      Clock.now()
      |> DateTime.diff(ramp_started_at, :second)
      |> div(@one_day)
      |> max(0)

    min(daily_cap, ramp_floor + days_elapsed * ramp_increment)
  end

  def effective_cap_today(%ChannelAdapter{daily_cap: daily_cap}), do: daily_cap

  @doc """
  Moves a resting adapter into probing when its cooldown has elapsed.
  """
  @spec recover_if_due(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t()} | :ok | {:error, term()}
  def recover_if_due(
        %ChannelAdapter{health_state: :resting, resting_until: %DateTime{} = resting_until} =
          adapter
      ) do
    if DateTime.compare(resting_until, Clock.now()) in [:lt, :eq] do
      case transition(adapter, :probing, reason: :resting_elapsed) do
        {:ok, updated, _events} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  def recover_if_due(%ChannelAdapter{}), do: :ok

  @doc """
  Evaluates one probing adapter for promotion or cooldown.
  """
  @spec evaluate_probe(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t()} | :ok | {:error, term()}
  def evaluate_probe(%ChannelAdapter{health_state: :probing} = adapter) do
    stats = probe_stats(adapter)

    cond do
      threshold_breached?(stats) ->
        rest_probe(adapter, stats)

      stats.sent_count >= outbound_default(:probe_min_sends, @default_probe_min_sends) ->
        case transition(adapter, :ramping, reason: :probe_success) do
          {:ok, updated, _events} -> {:ok, updated}
          {:error, reason} -> {:error, reason}
        end

      true ->
        :ok
    end
  end

  def evaluate_probe(%ChannelAdapter{}), do: :ok

  @doc """
  Evaluates all probing adapters.
  """
  @spec evaluate_probes() :: {:ok, non_neg_integer()} | {:error, term()}
  def evaluate_probes do
    ChannelAdapter
    |> where([adapter], adapter.health_state == ^:probing)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn adapter, {:ok, count} ->
      case evaluate_probe(adapter) do
        {:ok, _updated} -> {:cont, {:ok, count + 1}}
        :ok -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Applies a host-supplied health signal to an adapter.
  """
  @spec set_external_signal(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def set_external_signal(adapter_id, attrs) when is_map(attrs) do
    adapter = Repo.get!(ChannelAdapter, adapter_id)
    state = Map.get(attrs, :health_state, Map.get(attrs, "health_state"))
    score = Map.get(attrs, :health_score, Map.get(attrs, "health_score"))
    source = Map.get(attrs, :source, Map.get(attrs, "source"))

    with :ok <- validate_external_state(state),
         :ok <- validate_external_score(score),
         {:ok, updated, _events} <-
           transition(adapter, state,
             manual: true,
             reason: :external_signal,
             source: source,
             health_score: score
           ) do
      :telemetry.execute(
        [:dripdrop, :health, :external_signal],
        %{count: 1},
        %{
          adapter_id: updated.id,
          tenant_key: updated.tenant_key,
          health_state: updated.health_state,
          health_score: updated.health_score,
          source: source
        }
      )

      {:ok, updated}
    end
  end

  @doc false
  @spec allowed_transition?(atom() | nil, atom() | nil) :: boolean()
  def allowed_transition?(from, to), do: to in Map.get(@allowed_transitions, from, [])

  defp do_transition(adapter, new_state, opts) do
    old_state = adapter.health_state
    reason = Map.get(opts, :reason) || Map.get(opts, "reason")

    attrs =
      %{
        health_state: new_state,
        health_score:
          Map.get(opts, :health_score, Map.get(opts, "health_score", adapter.health_score)),
        resting_until:
          Map.get(opts, :resting_until, Map.get(opts, "resting_until", adapter.resting_until)),
        config: health_config(adapter.config, old_state, new_state, reason, opts)
      }
      |> maybe_put_ramp_started_at(adapter, old_state, new_state)

    case Repo.update(ChannelAdapter.changeset(adapter, attrs)) do
      {:ok, updated} ->
        emit_state_changed(updated, old_state, new_state, reason, opts)
        {:ok, updated, [:state_changed_event]}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_put_ramp_started_at(attrs, adapter, _old_state, :ramping) do
    Map.put(attrs, :ramp_started_at, adapter.ramp_started_at || Clock.now())
  end

  defp maybe_put_ramp_started_at(attrs, _adapter, _old_state, _new_state), do: attrs

  defp health_config(config, old_state, :probing, reason, opts) do
    config
    |> normalize_config()
    |> Map.merge(Map.get(opts, :config_merge, Map.get(opts, "config_merge", %{})))
    |> put_health("last_transition", transition_data(old_state, :probing, reason))
    |> put_health("probing_started_at", DateTime.to_iso8601(Clock.now()))
  end

  defp health_config(config, old_state, new_state, reason, opts) do
    config
    |> normalize_config()
    |> Map.merge(Map.get(opts, :config_merge, Map.get(opts, "config_merge", %{})))
    |> put_health("last_transition", transition_data(old_state, new_state, reason))
  end

  defp transition_data(old_state, new_state, reason) do
    %{
      "from" => state_to_string(old_state),
      "to" => state_to_string(new_state),
      "reason" => reason && to_string(reason),
      "at" => DateTime.to_iso8601(Clock.now())
    }
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(_config), do: %{}

  defp put_health(config, key, value) do
    Map.update(config, "health", %{key => value}, fn
      health when is_map(health) -> Map.put(health, key, value)
      _health -> %{key => value}
    end)
  end

  defp emit_state_changed(adapter, old_state, new_state, reason, opts) do
    :telemetry.execute(
      [:dripdrop, :health, :state_changed],
      %{count: 1},
      %{
        adapter_id: adapter.id,
        tenant_key: adapter.tenant_key,
        from: state_to_string(old_state),
        to: state_to_string(new_state),
        reason: reason,
        source: Map.get(opts, :source, Map.get(opts, "source"))
      }
    )
  end

  defp manual?(opts), do: Map.get(opts, :manual, Map.get(opts, "manual", false))

  defp state_to_string(nil), do: nil
  defp state_to_string(state), do: to_string(state)

  defp outbound_default(key, default) do
    case Application.get_env(:dripdrop, :outbound_defaults, []) do
      config when is_map(config) -> Map.get(config, key, Map.get(config, to_string(key), default))
      config when is_list(config) -> Keyword.get(config, key, default)
      _config -> default
    end
  end

  defp probe_stats(adapter) do
    since = Clock.seconds_from_now(-@one_day)

    MessageEvent
    |> where([event], event.occurred_at >= ^since)
    |> where([event], event.adapter_id == ^adapter.id)
    |> select([event], %{
      sent_count: filter(count(event.id), event.event_type == "sent"),
      bounce_count: filter(count(event.id), event.event_type == "bounced"),
      complaint_count: filter(count(event.id), event.event_type == "complained")
    })
    |> Repo.one()
    |> normalize_stats()
  end

  defp normalize_stats(nil), do: %{sent_count: 0, bounce_count: 0, complaint_count: 0}
  defp normalize_stats(stats), do: stats

  defp threshold_breached?(%{sent_count: 0}), do: false

  defp threshold_breached?(stats) do
    stats.bounce_count / stats.sent_count >= health_default(:bounce_rate, @default_bounce_rate) or
      stats.complaint_count / stats.sent_count >=
        health_default(:complaint_rate, @default_complaint_rate)
  end

  defp rest_probe(adapter, stats) do
    backoff_seconds = next_probe_backoff_seconds(adapter)
    resting_until = Clock.seconds_from_now(backoff_seconds)

    transition(adapter, :resting,
      reason: :probe_failure,
      resting_until: resting_until,
      config_merge: %{
        "probe_backoff_seconds" => backoff_seconds,
        "probe_failure" => %{
          "sent_count" => stats.sent_count,
          "bounce_count" => stats.bounce_count,
          "complaint_count" => stats.complaint_count
        }
      }
    )
    |> case do
      {:ok, updated, _events} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_probe_backoff_seconds(adapter) do
    previous =
      adapter.config
      |> normalize_config()
      |> Map.get("probe_backoff_seconds", @default_probe_backoff_seconds)

    previous
    |> normalize_integer(@default_probe_backoff_seconds)
    |> Kernel.*(2)
    |> min(@max_probe_backoff_seconds)
  end

  defp health_default(key, default) do
    :dripdrop
    |> Application.get_env(:bounce_complaint_thresholds, [])
    |> case do
      config when is_map(config) -> Map.get(config, key, Map.get(config, to_string(key), default))
      config when is_list(config) -> Keyword.get(config, key, default)
      _config -> default
    end
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp validate_external_state(state) when state in [:active, :resting, :probing, :ramping, nil],
    do: :ok

  defp validate_external_state(state) when state in ["active", "resting", "probing", "ramping"],
    do: :ok

  defp validate_external_state(_state), do: {:error, :invalid_health_state}

  defp validate_external_score(nil), do: :ok

  defp validate_external_score(score) when is_number(score) and score >= 0 and score <= 1,
    do: :ok

  defp validate_external_score(%Decimal{} = score) do
    if Decimal.compare(score, 0) in [:gt, :eq] and Decimal.compare(score, 1) in [:lt, :eq] do
      :ok
    else
      {:error, :invalid_health_score}
    end
  end

  defp validate_external_score(_score), do: {:error, :invalid_health_score}
end
