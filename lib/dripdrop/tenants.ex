defmodule DripDrop.Tenants do
  @moduledoc """
  Tenant-wide data operations.

  `delete_tenant/1` removes every DripDrop row a tenant owns, for hosts that
  delete an account. Every delete is filtered by `tenant_key`, so global rows
  (`tenant_key: nil`) and other tenants' rows are never selected.
  """

  import Ecto.Query

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    AdapterSequenceBudget,
    ChannelAdapter,
    Condition,
    Enrollment,
    Event,
    HttpHook,
    MessageEvent,
    Repo,
    Sequence,
    SequenceVersion,
    ShortLink,
    Step,
    StepExecution,
    StepTransition,
    Suppression,
    TenantScope
  }

  # Children before the rows they reference, so no delete depends on an
  # ON DELETE action to reach the tenant's own rows.
  @delete_order [
    message_events: MessageEvent,
    short_links: ShortLink,
    events: Event,
    conditions: Condition,
    step_executions: StepExecution,
    enrollments: Enrollment,
    step_transitions: StepTransition,
    adapter_sequence_budgets: AdapterSequenceBudget,
    http_hooks: HttpHook,
    steps: Step,
    sequence_versions: SequenceVersion,
    sequences: Sequence,
    adapter_pool_members: AdapterPoolMember,
    adapter_pools: AdapterPool,
    channel_adapters: ChannelAdapter,
    suppressions: Suppression
  ]

  # Every foreign key between DripDrop tables. A row outside the tenant that
  # points at one of the tenant's rows would be cascaded away or nulled by the
  # database when that row is deleted.
  @references [
    {AdapterPoolMember, :adapter_id, ChannelAdapter},
    {AdapterPoolMember, :pool_id, AdapterPool},
    {AdapterSequenceBudget, :adapter_id, ChannelAdapter},
    {AdapterSequenceBudget, :sequence_version_id, SequenceVersion},
    {Condition, :http_hook_id, HttpHook},
    {Condition, :step_id, Step},
    {Condition, :transition_id, StepTransition},
    {Enrollment, :adapter_id, ChannelAdapter},
    {Enrollment, :current_step_id, Step},
    {Enrollment, :sequence_id, Sequence},
    {Enrollment, :sequence_version_id, SequenceVersion},
    {Event, :enrollment_id, Enrollment},
    {HttpHook, :sequence_id, Sequence},
    {MessageEvent, :adapter_id, ChannelAdapter},
    {MessageEvent, :step_execution_id, StepExecution},
    {SequenceVersion, :sequence_id, Sequence},
    {ShortLink, :step_execution_id, StepExecution},
    {StepExecution, :enrollment_id, Enrollment},
    {StepExecution, :step_id, Step},
    {Step, :adapter_override_id, ChannelAdapter},
    {Step, :channel_adapter_id, ChannelAdapter},
    {Step, :sequence_version_id, SequenceVersion},
    {StepTransition, :from_step_id, Step},
    {StepTransition, :sequence_version_id, SequenceVersion},
    {StepTransition, :to_step_id, Step}
  ]

  @type cross_tenant_reference :: %{table: String.t(), column: atom(), count: pos_integer()}

  @doc """
  Deletes every DripDrop row owned by `tenant_key` in one transaction.

  Returns the deleted row count per table. When a row outside the tenant
  references one of the tenant's rows, nothing is deleted and the references
  are returned, since the delete would otherwise change that row too.

  `tenant_key` must be a non-blank string; global rows cannot be deleted
  through this function.
  """
  @spec delete_tenant(String.t()) ::
          {:ok, %{atom() => non_neg_integer()}}
          | {:error, {:cross_tenant_references, [cross_tenant_reference()]}}
  def delete_tenant(tenant_key) when is_binary(tenant_key) and tenant_key != "" do
    repo = Repo.repo!()

    repo.transaction(fn ->
      case cross_tenant_references(tenant_key) do
        [] -> delete_rows(repo, tenant_key)
        references -> repo.rollback({:cross_tenant_references, references})
      end
    end)
  end

  def delete_tenant(_tenant_key), do: TenantScope.raise_missing!(:delete_tenant)

  defp cross_tenant_references(tenant_key) do
    for {child, column, parent} <- @references,
        count = cross_tenant_reference_count(child, column, parent, tenant_key),
        count > 0 do
      %{table: child.__schema__(:source), column: column, count: count}
    end
  end

  defp cross_tenant_reference_count(child, column, parent, tenant_key) do
    child
    |> join(:inner, [row], owner in ^parent, on: field(row, ^column) == owner.id)
    |> where([_row, owner], owner.tenant_key == ^tenant_key)
    |> where([row], is_nil(row.tenant_key) or row.tenant_key != ^tenant_key)
    |> select([row], count())
    |> Repo.one()
  end

  defp delete_rows(repo, tenant_key) do
    Map.new(@delete_order, fn {table, schema} ->
      {count, _rows} =
        schema
        |> where([row], row.tenant_key == ^tenant_key)
        |> repo.delete_all()

      {table, count}
    end)
  end
end
