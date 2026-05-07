defmodule DripDrop.ChannelAdapters do
  @moduledoc """
  Context for creating, updating, and selecting channel adapters.
  """

  import Ecto.Query

  alias DripDrop.{ChannelAdapter, Channels, Repo, TenantScope}
  alias Ecto.{Changeset, Multi}

  @type list_filters :: %{
          optional(:tenant_key) => binary() | nil,
          optional(:channel) => binary(),
          optional(:active) => boolean()
        }

  @spec create_channel_adapter(map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Changeset.t()}
  @doc """
  Creates a channel adapter and atomically promotes it when `is_default` is true.
  """
  def create_channel_adapter(attrs) when is_map(attrs) do
    changeset = ChannelAdapter.changeset(%ChannelAdapter{}, attrs)

    if Changeset.get_field(changeset, :is_default) do
      promote_new_default(changeset)
    else
      Repo.insert(changeset)
    end
  end

  @spec update_channel_adapter(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Changeset.t()}
  @doc """
  Updates a channel adapter and demotes the previous scoped default when needed.
  """
  def update_channel_adapter(%ChannelAdapter{} = adapter, attrs) when is_map(attrs) do
    changeset = ChannelAdapter.changeset(adapter, attrs)

    if Changeset.get_field(changeset, :is_default) do
      promote_existing_default(changeset)
    else
      Repo.update(changeset)
    end
  end

  @spec list_channel_adapters(list_filters()) :: [Ecto.Schema.t()]
  @doc """
  Lists channel adapters using optional tenant, channel, and active filters.
  """
  def list_channel_adapters(filters \\ %{}) do
    tenant_key = TenantScope.fetch!(filters, :list_channel_adapters)

    ChannelAdapter
    |> where_tenant_scope(tenant_key)
    |> maybe_where(:channel, Map.get(filters, :channel))
    |> maybe_where(:active, Map.get(filters, :active))
    |> order_by([adapter], asc: adapter.channel, asc: adapter.name)
    |> Repo.all()
  end

  @doc """
  Gets an active channel adapter by id.
  """
  @spec get_active_adapter(Ecto.UUID.t() | binary()) :: Ecto.Schema.t() | nil
  def get_active_adapter(adapter_id) do
    ChannelAdapter
    |> where([adapter], adapter.id == ^adapter_id)
    |> where([adapter], adapter.active)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns webhook routes exposed by active provider adapters.
  """
  @spec webhook_routes() :: [DripDrop.Channel.webhook_route()]
  def webhook_routes do
    ChannelAdapter
    |> where([adapter], adapter.active)
    |> Repo.all()
    |> Enum.flat_map(&adapter_routes/1)
  end

  @spec get_default_adapter(binary() | atom(), binary() | nil) :: Ecto.Schema.t() | nil
  @doc """
  Returns the active default adapter for a channel, preferring the tenant default.
  """
  def get_default_adapter(channel, tenant_key) do
    channel = to_string(channel)

    scoped_default(channel, tenant_key) || scoped_default(channel, nil)
  end

  @spec select(term(), term(), term()) ::
          {:ok, Ecto.Schema.t()} | {:error, %{kind: :permanent, reason: :no_adapter}}
  @doc """
  Selects the adapter for a step using explicit, rotation, sequence, and default fallbacks.
  """
  def select(step, sequence, step_execution) do
    with nil <- explicit_step_adapter(step),
         nil <- rotated_adapter(step, sequence, step_execution),
         nil <- sequence_adapter(step, sequence),
         nil <- get_default_adapter(step.channel, step.tenant_key) do
      {:error, %{kind: :permanent, reason: :no_adapter}}
    else
      %ChannelAdapter{} = adapter -> {:ok, adapter}
    end
  end

  defp promote_new_default(changeset) do
    Multi.new()
    |> Multi.update_all(:demote_previous, defaults_query(changeset), set: [is_default: false])
    |> Multi.insert(:adapter, changeset)
    |> Repo.transaction()
    |> unwrap_transaction(:adapter)
  end

  defp promote_existing_default(changeset) do
    Multi.new()
    |> Multi.update_all(:demote_previous, defaults_query(changeset), set: [is_default: false])
    |> Multi.update(:adapter, changeset)
    |> Repo.transaction()
    |> unwrap_transaction(:adapter)
  end

  defp defaults_query(changeset) do
    channel = Changeset.get_field(changeset, :channel)
    tenant_key = Changeset.get_field(changeset, :tenant_key)
    id = Changeset.get_field(changeset, :id)

    ChannelAdapter
    |> where([adapter], adapter.channel == ^channel)
    |> where_tenant_default(tenant_key)
    |> maybe_exclude(id)
  end

  defp where_tenant_default(query, nil), do: where(query, [adapter], is_nil(adapter.tenant_key))

  defp where_tenant_default(query, tenant_key),
    do: where(query, [adapter], adapter.tenant_key == ^tenant_key)

  defp maybe_exclude(query, nil), do: query
  defp maybe_exclude(query, id), do: where(query, [adapter], adapter.id != ^id)

  defp unwrap_transaction({:ok, %{adapter: adapter}}, _key), do: {:ok, adapter}
  defp unwrap_transaction({:error, _step, reason, _changes}, _key), do: {:error, reason}

  defp scoped_default(channel, tenant_key) do
    ChannelAdapter
    |> where([adapter], adapter.channel == ^channel)
    |> where([adapter], adapter.is_default)
    |> where([adapter], adapter.active)
    |> where_tenant_default(tenant_key)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) do
    where(query, [adapter], field(adapter, ^field) == ^value)
  end

  defp adapter_routes(adapter) do
    case Channels.provider_module(adapter.channel, adapter.provider) do
      {:ok, provider} -> provider.webhook_routes(adapter)
      _unknown -> []
    end
  end

  defp where_tenant_scope(query, nil), do: where(query, [adapter], is_nil(adapter.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [adapter], adapter.tenant_key == ^tenant_key)

  defp explicit_step_adapter(%{
         channel_adapter: %ChannelAdapter{active: true, channel: channel} = adapter,
         channel: channel
       }),
       do: adapter

  defp explicit_step_adapter(%{channel_adapter_id: nil}), do: nil

  defp explicit_step_adapter(%{channel_adapter_id: adapter_id, channel: channel})
       when is_binary(adapter_id) do
    adapter_by_id(adapter_id, channel)
  end

  defp explicit_step_adapter(_step), do: nil

  defp rotated_adapter(step, sequence, step_execution) do
    rotation = step_rotation(step) || sequence_rotation(step, sequence)

    select_rotated_adapter(rotation, step, step_execution)
  end

  defp sequence_adapter(%{channel: channel}, %{metadata: %{"channel_adapters" => adapters}}) do
    adapter_id = Map.get(adapters, channel)

    if adapter_id, do: adapter_by_id(adapter_id, channel), else: nil
  end

  defp sequence_adapter(_step, _sequence), do: nil

  defp step_rotation(%{config: %{"channel_adapter_rotation" => rotation}}), do: rotation

  defp step_rotation(_step), do: nil

  defp sequence_rotation(%{channel: channel}, %{metadata: %{"channel_rotation" => rotations}}) do
    Map.get(rotations, channel) || Map.get(rotations, "default")
  end

  defp sequence_rotation(_step, _sequence), do: nil

  defp select_rotated_adapter(nil, _step, _step_execution), do: nil
  defp select_rotated_adapter([], _step, _step_execution), do: nil

  defp select_rotated_adapter(rotation, %{channel: channel}, step_execution)
       when is_list(rotation) do
    rotation
    |> normalize_rotation_entries()
    |> pick_entry(rotation_key(step_execution))
    |> case do
      nil -> nil
      %{adapter_id: adapter_id} -> adapter_by_id(adapter_id, channel)
    end
  end

  defp select_rotated_adapter(_rotation, _step, _step_execution), do: nil

  defp normalize_rotation_entries(rotation) do
    Enum.flat_map(rotation, fn
      %{"adapter_id" => adapter_id, "weight" => weight} ->
        [%{adapter_id: adapter_id, weight: normalize_weight(weight)}]

      %{adapter_id: adapter_id, weight: weight} ->
        [%{adapter_id: adapter_id, weight: normalize_weight(weight)}]

      adapter_id when is_binary(adapter_id) ->
        [%{adapter_id: adapter_id, weight: 1}]

      _entry ->
        []
    end)
  end

  defp pick_entry([], _key), do: nil

  defp pick_entry(entries, key) do
    total = Enum.reduce(entries, 0, fn entry, sum -> sum + entry.weight end)
    slot = :erlang.phash2(key, total)

    Enum.reduce_while(entries, slot, fn entry, remaining ->
      if remaining < entry.weight do
        {:halt, entry}
      else
        {:cont, remaining - entry.weight}
      end
    end)
  end

  defp adapter_by_id(adapter_id, channel) do
    ChannelAdapter
    |> where([adapter], adapter.id == ^adapter_id)
    |> where([adapter], adapter.channel == ^channel)
    |> where([adapter], adapter.active)
    |> limit(1)
    |> Repo.one()
  end

  defp rotation_key(%{id: id}) when not is_nil(id), do: id
  defp rotation_key(step_execution), do: inspect(step_execution)

  defp normalize_weight(weight) when is_integer(weight) and weight > 0, do: weight

  defp normalize_weight(weight) when is_binary(weight) do
    case Integer.parse(weight) do
      {value, ""} when value > 0 -> value
      _invalid -> 1
    end
  end

  defp normalize_weight(_weight), do: 1
end
