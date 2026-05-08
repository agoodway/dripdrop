defmodule DripDrop.AdapterPools.WDRR do
  @moduledoc """
  Smooth weighted round-robin allocator for outbound adapter pools.

  Counters live in ETS and reset on application restart. The database remains
  the source of truth for membership, adapter health, and capacity.
  """

  use GenServer

  import Ecto.Query

  alias DripDrop.{
    AdapterHealth,
    AdapterPool,
    AdapterPoolMember,
    MessageEvent,
    Repo,
    SequenceVersion
  }

  @table __MODULE__
  @active_health_states [:active, :ramping, :probing]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    ensure_table!()
    {:ok, %{}}
  end

  @doc """
  Picks one eligible member for a pool and sequence version.
  """
  @spec pick_member(AdapterPool.t(), SequenceVersion.t()) ::
          {:ok, AdapterPoolMember.t()} | {:error, :pool_exhausted}
  def pick_member(%AdapterPool{} = pool, %SequenceVersion{} = sequence_version) do
    ensure_table!()

    members =
      pool.id
      |> active_members()
      |> Enum.filter(&eligible_member?(&1, sequence_version))

    case members do
      [] -> {:error, :pool_exhausted}
      members -> {:ok, pick_weighted_member(members, sequence_version)}
    end
  end

  @doc """
  Picks a member whose adapter is enabled (`active = true`), without health or
  cap filtering. Used by enrollment-time reassign when every regular candidate
  has been exhausted and we need *some* pin so the enrollment can proceed.
  """
  @spec pick_active_member(AdapterPool.t(), SequenceVersion.t()) ::
          {:ok, AdapterPoolMember.t()} | {:error, :pool_exhausted}
  def pick_active_member(%AdapterPool{} = pool, %SequenceVersion{} = sequence_version) do
    ensure_table!()

    members =
      pool.id
      |> active_members()
      |> Enum.filter(&active_adapter?/1)

    case members do
      [] -> {:error, :pool_exhausted}
      members -> {:ok, pick_weighted_member(members, sequence_version)}
    end
  end

  @doc """
  Picks a member whose adapter is currently in a usable health state, ignoring
  daily-cap headroom. Used by dispatch-time auto-rebind: if the pinned adapter
  has gone resting or inactive we need a sender that can send right now, not
  one that is itself resting.
  """
  @spec pick_healthy_member(AdapterPool.t(), SequenceVersion.t()) ::
          {:ok, AdapterPoolMember.t()} | {:error, :pool_exhausted}
  def pick_healthy_member(%AdapterPool{} = pool, %SequenceVersion{} = sequence_version) do
    ensure_table!()

    members =
      pool.id
      |> active_members()
      |> Enum.filter(&healthy_member?/1)

    case members do
      [] -> {:error, :pool_exhausted}
      members -> {:ok, pick_weighted_member(members, sequence_version)}
    end
  end

  @doc false
  @spec reset!() :: :ok
  def reset! do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl GenServer
  def handle_call(:noop, _from, state), do: {:reply, :ok, state}

  defp active_members(pool_id) do
    AdapterPoolMember
    |> where([member], member.pool_id == ^pool_id)
    |> where([member], member.active)
    |> preload(:adapter)
    |> order_by([member], asc: member.id)
    |> Repo.all()
    |> Enum.map(&recover_member_adapter/1)
  end

  defp recover_member_adapter(%AdapterPoolMember{adapter: adapter} = member) do
    case AdapterHealth.recover_if_due(adapter) do
      {:ok, updated} -> %{member | adapter: updated}
      _not_updated -> member
    end
  end

  defp eligible_member?(%AdapterPoolMember{adapter: nil}, _sequence_version), do: false

  defp eligible_member?(%AdapterPoolMember{adapter: adapter}, sequence_version) do
    adapter.active and adapter.health_state in @active_health_states and
      has_daily_headroom?(adapter, sequence_version)
  end

  defp active_adapter?(%AdapterPoolMember{adapter: %{active: true}}), do: true
  defp active_adapter?(_member), do: false

  defp healthy_member?(%AdapterPoolMember{adapter: %{active: true} = adapter}),
    do: adapter.health_state in @active_health_states

  defp healthy_member?(_member), do: false

  defp has_daily_headroom?(adapter, sequence_version) do
    case AdapterHealth.effective_cap_today(adapter) do
      nil -> true
      cap -> sent_count_today(adapter.id, sequence_version.tenant_key) < cap
    end
  end

  defp sent_count_today(adapter_id, tenant_key) do
    day_start =
      DateTime.utc_now(:second) |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    MessageEvent
    |> where([event], event.event_type == "sent")
    |> where([event], event.occurred_at >= ^day_start)
    |> where([event], event.adapter_id == ^adapter_id)
    |> where_tenant_scope(tenant_key)
    |> Repo.repo!().aggregate(:count)
  end

  defp pick_weighted_member(members, sequence_version) do
    total = Enum.reduce(members, 0, fn member, sum -> sum + member.weight end)

    weighted =
      Enum.map(members, fn member ->
        key = key(member, sequence_version)
        current = :ets.update_counter(@table, key, {2, member.weight}, {key, 0})
        {member, key, current}
      end)

    {member, key, _current} =
      Enum.max_by(weighted, fn {member, _key, current} -> {current, member.weight} end)

    _updated = :ets.update_counter(@table, key, {2, -total})
    member
  end

  defp key(%AdapterPoolMember{} = member, %SequenceVersion{} = sequence_version) do
    {member.pool_id, sequence_version.id, member.adapter_id}
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _tid ->
        :ok
    end
  end

  defp where_tenant_scope(query, nil), do: where(query, [event], is_nil(event.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [event], event.tenant_key == ^tenant_key)
end
