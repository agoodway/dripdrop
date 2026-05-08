defmodule DripDrop.Policy.AdapterHealthCheck do
  @moduledoc """
  Outbound-only dispatch gate for adapter health state.
  """

  alias DripDrop.Clock

  @healthy_states [:active, :ramping, :probing]
  @terminal_pause_seconds 7 * 86_400

  @doc """
  Allows healthy outbound adapters and defers resting adapters.
  """
  @spec check(map(), Ecto.Schema.t()) ::
          :ok | {:defer, DateTime.t(), map()} | {:error, map()}
  def check(context, adapter) do
    case adapter.health_state do
      state when state in @healthy_states or is_nil(state) ->
        :ok

      :resting ->
        resting(context, adapter)
    end
  end

  @doc """
  Returns true when an adapter is unavailable enough to pause an enrollment.
  """
  @spec terminally_unavailable?(Ecto.Schema.t() | nil) :: boolean()
  def terminally_unavailable?(nil), do: true
  def terminally_unavailable?(%{active: false}), do: true

  def terminally_unavailable?(%{
        health_state: :resting,
        resting_until: %DateTime{} = resting_until
      }) do
    DateTime.compare(resting_until, Clock.seconds_from_now(@terminal_pause_seconds)) == :gt
  end

  def terminally_unavailable?(_adapter), do: false

  defp resting(context, adapter) do
    defer_until = adapter.resting_until || Clock.seconds_from_now(300)

    :telemetry.execute([:dripdrop, :policy, :adapter_resting], %{count: 1}, %{
      adapter_id: adapter.id,
      step_execution_id: context.execution.id,
      tenant_key: context.execution.tenant_key,
      defer_until: defer_until
    })

    {:defer, defer_until,
     %{
       reason: "adapter_resting",
       adapter_id: adapter.id,
       resting_until: defer_until
     }}
  end
end
