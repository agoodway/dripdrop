defmodule DripDrop.Policy.SubCap do
  @moduledoc """
  Outbound-only per-sequence share cap for a pinned adapter.
  """

  import Ecto.Query

  alias DripDrop.{
    AdapterHealth,
    AdapterSequenceBudgets,
    Clock,
    MessageEvent,
    Repo,
    StepExecution
  }

  @doc """
  Defers when a sequence has exhausted its configured share of an adapter's cap.
  """
  @spec check(map(), Ecto.Schema.t()) :: :ok | {:defer, DateTime.t(), map()}
  def check(context, adapter) do
    case AdapterHealth.effective_cap_today(adapter) do
      nil ->
        :ok

      cap when is_integer(cap) ->
        check_cap(context, adapter, cap)
    end
  end

  defp check_cap(context, adapter, cap) do
    case AdapterSequenceBudgets.get_or_create_budget(
           adapter.id,
           context.enrollment.sequence_version_id
         ) do
      {:ok, budget} ->
        evaluate_share_cap(context, adapter, cap, budget)

      {:error, _reason} ->
        emit_budget_conflict(context, adapter)

        {:defer, retry_after_conflict(),
         %{
           reason: "budget_create_conflict",
           adapter_id: adapter.id,
           sequence_version_id: context.enrollment.sequence_version_id
         }}
    end
  end

  defp evaluate_share_cap(context, adapter, cap, budget) do
    share_cap = max(1, floor(cap * budget.max_share_pct / 100))

    count =
      sent_today(
        adapter.id,
        context.enrollment.sequence_version_id,
        context.execution.tenant_key
      )

    if count >= share_cap do
      emit(context, adapter, count, share_cap, budget.max_share_pct)

      {:defer, next_day(),
       %{
         reason: "sub_cap",
         adapter_id: adapter.id,
         sequence_version_id: context.enrollment.sequence_version_id,
         sent_count: count,
         cap: share_cap
       }}
    else
      :ok
    end
  end

  defp sent_today(adapter_id, sequence_version_id, tenant_key) do
    MessageEvent
    |> join(:inner, [event], execution in StepExecution,
      on: execution.id == event.step_execution_id
    )
    |> where([event, execution], event.event_type == "sent")
    |> where([event, execution], event.occurred_at >= ^day_start())
    |> where(
      [event, execution],
      execution.enrollment_id in subquery(enrollment_ids(sequence_version_id))
    )
    |> where([event, execution], event.adapter_id == ^adapter_id)
    |> where_tenant_scope(tenant_key)
    |> Repo.repo!().aggregate(:count)
  end

  defp enrollment_ids(sequence_version_id) do
    from(enrollment in DripDrop.Enrollment,
      where: enrollment.sequence_version_id == ^sequence_version_id,
      select: enrollment.id
    )
  end

  defp emit(context, adapter, count, cap, max_share_pct) do
    :telemetry.execute([:dripdrop, :policy, :sub_cap], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      adapter_id: adapter.id,
      sequence_version_id: context.enrollment.sequence_version_id,
      sent_count: count,
      cap: cap,
      max_share_pct: max_share_pct
    })
  end

  defp emit_budget_conflict(context, adapter) do
    :telemetry.execute([:dripdrop, :policy, :sub_cap, :budget_conflict], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      adapter_id: adapter.id,
      sequence_version_id: context.enrollment.sequence_version_id
    })
  end

  defp day_start, do: Clock.now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  defp next_day, do: DateTime.add(day_start(), 86_400, :second)
  defp retry_after_conflict, do: DateTime.add(Clock.now(), 60, :second)

  defp where_tenant_scope(query, nil),
    do: where(query, [event, _execution], is_nil(event.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [event, _execution], event.tenant_key == ^tenant_key)
end
