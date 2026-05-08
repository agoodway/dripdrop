defmodule DripDrop.AdapterSequenceBudgets do
  @moduledoc """
  Context for managing outbound adapter sequence budgets.
  """

  import Ecto.Query

  alias DripDrop.{AdapterSequenceBudget, ChannelAdapter, Repo}

  @doc """
  Creates or updates a per-adapter, per-sequence budget.

  The budget's `tenant_key` is inherited from the adapter so tenant scope is
  enforced at the row level even though the unique key is `(adapter_id,
  sequence_version_id)`.
  """
  @spec set_adapter_sequence_budget(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def set_adapter_sequence_budget(adapter_id, sequence_version_id, attrs \\ %{})
      when is_binary(adapter_id) and is_binary(sequence_version_id) and is_map(attrs) do
    attrs =
      attrs
      |> Map.put(:adapter_id, adapter_id)
      |> Map.put(:sequence_version_id, sequence_version_id)
      |> put_tenant_key_from_adapter(adapter_id)

    case get_budget(adapter_id, sequence_version_id) do
      %AdapterSequenceBudget{} = budget ->
        budget
        |> AdapterSequenceBudget.changeset(attrs)
        |> Repo.update()

      nil ->
        %AdapterSequenceBudget{}
        |> AdapterSequenceBudget.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp put_tenant_key_from_adapter(attrs, adapter_id) do
    case Repo.get(ChannelAdapter, adapter_id) do
      %ChannelAdapter{tenant_key: tenant_key} -> Map.put_new(attrs, :tenant_key, tenant_key)
      nil -> attrs
    end
  end

  @doc """
  Gets an existing budget or creates the default lazy budget.

  Race-safe: concurrent callers go through an upsert with `on_conflict: :nothing`
  on the (adapter_id, sequence_version_id) unique index, then re-fetch.
  """
  @spec get_or_create_budget(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t() | :budget_unavailable}
  def get_or_create_budget(adapter_id, sequence_version_id) do
    case get_budget(adapter_id, sequence_version_id) do
      %AdapterSequenceBudget{} = budget ->
        {:ok, budget}

      nil ->
        upsert_default_budget(adapter_id, sequence_version_id)
    end
  end

  defp upsert_default_budget(adapter_id, sequence_version_id) do
    attrs =
      %{adapter_id: adapter_id, sequence_version_id: sequence_version_id}
      |> put_tenant_key_from_adapter(adapter_id)

    changeset = AdapterSequenceBudget.changeset(%AdapterSequenceBudget{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:adapter_id, :sequence_version_id]
         ) do
      {:ok, _maybe_inserted} ->
        case get_budget(adapter_id, sequence_version_id) do
          %AdapterSequenceBudget{} = budget -> {:ok, budget}
          nil -> {:error, :budget_unavailable}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gets a budget by adapter and sequence version.
  """
  @spec get_budget(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Schema.t() | nil
  def get_budget(adapter_id, sequence_version_id) do
    AdapterSequenceBudget
    |> where([budget], budget.adapter_id == ^adapter_id)
    |> where([budget], budget.sequence_version_id == ^sequence_version_id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Lists budgets for optional adapter and sequence-version filters.
  """
  @spec list_budgets(map()) :: [Ecto.Schema.t()]
  def list_budgets(filters \\ %{}) do
    AdapterSequenceBudget
    |> maybe_where(:adapter_id, Map.get(filters, :adapter_id))
    |> maybe_where(:sequence_version_id, Map.get(filters, :sequence_version_id))
    |> order_by([budget], asc: budget.inserted_at)
    |> Repo.all()
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value) do
    where(query, [budget], field(budget, ^field) == ^value)
  end
end
