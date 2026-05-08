defmodule DripDrop.Policy.AdapterPause do
  @moduledoc """
  Defers dispatch when a channel adapter has been paused by the
  bounce/complaint threshold checker.

  `DripDrop.Policy.BounceComplaintThresholds` writes `paused_until` and
  `paused_reason` into `channel_adapters.config` when an adapter's rolling
  rates breach the configured limits. This module is the read-side that
  actually blocks dispatch through such an adapter until the cooldown
  expires.

  Stale or unparseable `paused_until` values are treated as "not paused"
  (logged via telemetry) so a corrupted config field cannot wedge dispatch.
  """

  alias DripDrop.Clock

  @doc """
  Returns `:ok` for unpaused adapters, `{:defer, defer_until, metadata}`
  for adapters whose `paused_until` is in the future.
  """
  @spec check(map(), map()) :: :ok | {:defer, DateTime.t(), map()}
  def check(context, adapter) do
    case parse_paused_until(adapter) do
      :not_paused ->
        :ok

      :unparseable ->
        emit_parse_warning(context, adapter)
        :ok

      %DateTime{} = paused_until ->
        if DateTime.compare(paused_until, Clock.now()) == :gt do
          emit_paused(context, adapter, paused_until)

          {:defer, paused_until,
           %{
             reason: "adapter_paused",
             paused_reason: paused_reason(adapter),
             paused_until: paused_until,
             adapter_id: adapter.id
           }}
        else
          :ok
        end
    end
  end

  defp parse_paused_until(%{config: %{"paused_until" => value}}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> :unparseable
    end
  end

  defp parse_paused_until(_adapter), do: :not_paused

  defp paused_reason(%{config: %{"paused_reason" => reason}}), do: reason
  defp paused_reason(_adapter), do: nil

  defp emit_paused(context, adapter, paused_until) do
    :telemetry.execute([:dripdrop, :policy, :adapter_paused], %{count: 1}, %{
      adapter_id: adapter.id,
      paused_reason: paused_reason(adapter),
      paused_until: paused_until,
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key
    })
  end

  defp emit_parse_warning(context, adapter) do
    :telemetry.execute(
      [:dripdrop, :policy, :adapter_paused, :parse_warning],
      %{count: 1},
      %{
        adapter_id: adapter.id,
        raw_value: get_in(adapter.config, ["paused_until"]),
        step_execution_id: context.execution.id,
        tenant_key: context.execution.tenant_key
      }
    )
  end
end
