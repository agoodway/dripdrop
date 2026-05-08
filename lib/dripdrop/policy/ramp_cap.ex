defmodule DripDrop.Policy.RampCap do
  @moduledoc """
  Outbound-only daily cap enforcement using adapter ramp state.
  """

  import Ecto.Query

  alias DripDrop.{AdapterHealth, Clock, MessageEvent, Repo}

  @doc """
  Defers when the adapter has already used today's effective cap.
  """
  @spec check(map(), Ecto.Schema.t()) :: :ok | {:defer, DateTime.t(), map()}
  def check(context, adapter) do
    case AdapterHealth.effective_cap_today(adapter) do
      nil ->
        :ok

      cap ->
        count = sent_today(adapter.id, context.execution.tenant_key)

        if count >= cap do
          emit(context, adapter, count, cap)

          {:defer, next_day(),
           %{reason: "ramp_cap", adapter_id: adapter.id, sent_count: count, cap: cap}}
        else
          :ok
        end
    end
  end

  @doc false
  @spec sent_today(Ecto.UUID.t(), binary() | nil) :: non_neg_integer()
  def sent_today(adapter_id, tenant_key) do
    MessageEvent
    |> where([event], event.event_type == "sent")
    |> where([event], event.occurred_at >= ^day_start())
    |> where([event], event.adapter_id == ^adapter_id)
    |> where_tenant_scope(tenant_key)
    |> Repo.repo!().aggregate(:count)
  end

  defp emit(context, adapter, count, cap) do
    :telemetry.execute([:dripdrop, :policy, :ramp_cap], %{count: 1}, %{
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      adapter_id: adapter.id,
      sent_count: count,
      cap: cap
    })
  end

  defp day_start, do: Clock.now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  defp next_day, do: DateTime.add(day_start(), 86_400, :second)

  defp where_tenant_scope(query, nil), do: where(query, [event], is_nil(event.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [event], event.tenant_key == ^tenant_key)
end
