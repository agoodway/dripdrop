defmodule DripDrop.AdapterPools do
  @moduledoc """
  Context for authoring outbound adapter pools and memberships.
  """

  import Ecto.Query

  alias Ecto.Changeset

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    ChannelAdapter,
    Enrollment,
    Repo,
    SequenceVersion,
    TenantScope
  }

  @type tenant_filters :: %{required(:tenant_key) => binary() | nil}

  @doc """
  Creates an adapter pool in an explicit tenant scope.
  """
  @spec create_adapter_pool(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_adapter_pool(attrs) when is_list(attrs),
    do: attrs |> Map.new() |> create_adapter_pool()

  def create_adapter_pool(attrs) when is_map(attrs) do
    _tenant_key = TenantScope.fetch!(attrs, :create_adapter_pool)

    %AdapterPool{}
    |> AdapterPool.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an adapter pool after verifying the caller's tenant scope.
  """
  @spec update_adapter_pool(Ecto.Schema.t() | Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def update_adapter_pool(pool_or_id, attrs) when is_map(attrs) do
    tenant_key = TenantScope.fetch!(attrs, :update_adapter_pool)
    pool = scoped_pool!(pool_or_id, tenant_key)

    pool
    |> AdapterPool.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an adapter pool unless active outbound enrollments still use it.
  """
  @spec delete_adapter_pool(Ecto.Schema.t() | Ecto.UUID.t(), map() | keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, map()}
  def delete_adapter_pool(pool_or_id, opts) when is_list(opts),
    do: delete_adapter_pool(pool_or_id, Map.new(opts))

  def delete_adapter_pool(pool_or_id, opts) when is_map(opts) do
    tenant_key = TenantScope.fetch!(opts, :delete_adapter_pool)
    pool = scoped_pool!(pool_or_id, tenant_key)
    active_count = active_enrollment_count(pool)

    if active_count > 0 and not Map.get(opts, :force, Map.get(opts, "force", false)) do
      {:error, %{reason: :pool_in_use, active_enrollment_count: active_count}}
    else
      Repo.repo!().delete(pool)
    end
  end

  @doc """
  Lists adapter pools in an explicit tenant scope.
  """
  @spec list_adapter_pools(tenant_filters()) :: [Ecto.Schema.t()]
  def list_adapter_pools(filters) when is_map(filters) do
    tenant_key = TenantScope.fetch!(filters, :list_adapter_pools)

    AdapterPool
    |> where_tenant_scope(tenant_key)
    |> order_by([pool], asc: pool.name)
    |> Repo.all()
  end

  @doc """
  Adds a channel adapter to a pool.
  """
  @spec add_pool_member(Ecto.Schema.t() | Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def add_pool_member(pool_or_id, attrs) when is_map(attrs) do
    tenant_key = TenantScope.fetch!(attrs, :add_pool_member)
    pool = scoped_pool!(pool_or_id, tenant_key)

    attrs =
      attrs
      |> Map.put(:pool_id, pool.id)
      |> Map.put(:tenant_key, pool.tenant_key)

    changeset = AdapterPoolMember.changeset(%AdapterPoolMember{}, attrs)

    with :ok <- adapter_tenant_matches(changeset, tenant_key) do
      Repo.insert(changeset)
    end
  end

  @doc """
  Removes one adapter from a pool without mutating existing enrollment pins.
  """
  @spec remove_pool_member(Ecto.Schema.t() | Ecto.UUID.t(), Ecto.UUID.t() | map()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found}
  def remove_pool_member(pool_or_id, %{tenant_key: tenant_key, adapter_id: adapter_id}) do
    pool = scoped_pool!(pool_or_id, tenant_key)
    remove_pool_member_by_adapter(pool.id, adapter_id)
  end

  def remove_pool_member(pool_or_id, %{"tenant_key" => tenant_key, "adapter_id" => adapter_id}) do
    pool = scoped_pool!(pool_or_id, tenant_key)
    remove_pool_member_by_adapter(pool.id, adapter_id)
  end

  @doc """
  Lists members for a pool in an explicit tenant scope.
  """
  @spec list_pool_members(Ecto.Schema.t() | Ecto.UUID.t() | map()) :: [Ecto.Schema.t()]
  def list_pool_members(%{pool_id: pool_id, tenant_key: tenant_key}) do
    pool_id
    |> scoped_pool!(tenant_key)
    |> list_pool_members()
  end

  def list_pool_members(%{"pool_id" => pool_id, "tenant_key" => tenant_key}) do
    pool_id
    |> scoped_pool!(tenant_key)
    |> list_pool_members()
  end

  def list_pool_members(%AdapterPool{} = pool) do
    AdapterPoolMember
    |> where([member], member.pool_id == ^pool.id)
    |> preload(:adapter)
    |> order_by([member], desc: member.active, desc: member.weight, asc: member.id)
    |> Repo.all()
  end

  defp remove_pool_member_by_adapter(pool_id, adapter_id) do
    AdapterPoolMember
    |> where([member], member.pool_id == ^pool_id)
    |> where([member], member.adapter_id == ^adapter_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      member -> Repo.repo!().delete(member)
    end
  end

  defp adapter_tenant_matches(changeset, tenant_key) do
    adapter_id = Changeset.get_field(changeset, :adapter_id)

    case Repo.get(ChannelAdapter, adapter_id) do
      %ChannelAdapter{tenant_key: ^tenant_key} ->
        :ok

      %ChannelAdapter{} ->
        {:error, Changeset.add_error(changeset, :adapter_id, "tenant_mismatch")}

      nil ->
        {:error, Changeset.add_error(changeset, :adapter_id, "adapter_not_found")}
    end
  end

  defp scoped_pool!(%AdapterPool{tenant_key: tenant_key} = pool, tenant_key), do: pool

  defp scoped_pool!(%AdapterPool{}, _tenant_key),
    do: raise(Ecto.NoResultsError, queryable: AdapterPool)

  defp scoped_pool!(pool_id, tenant_key) when is_binary(pool_id) do
    AdapterPool
    |> where([pool], pool.id == ^pool_id)
    |> where_tenant_scope(tenant_key)
    |> Repo.one()
    |> case do
      nil -> raise(Ecto.NoResultsError, queryable: AdapterPool)
      pool -> pool
    end
  end

  defp active_enrollment_count(%AdapterPool{} = pool) do
    pool_id = pool.id

    Enrollment
    |> join(:inner, [enrollment], version in SequenceVersion,
      on: version.id == enrollment.sequence_version_id
    )
    |> where([enrollment], enrollment.state in ["active", "paused"])
    |> where([enrollment, version], version.config["pool_id"] == ^pool_id)
    |> Repo.repo!().aggregate(:count)
  end

  defp where_tenant_scope(query, nil), do: where(query, [pool], is_nil(pool.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [pool], pool.tenant_key == ^tenant_key)
end
