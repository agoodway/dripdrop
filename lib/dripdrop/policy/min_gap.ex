defmodule DripDrop.Policy.MinGap do
  @moduledoc """
  Outbound-only minimum gap enforcement between sends from one adapter.
  """

  alias DripDrop.Clock

  @doc """
  Defers until `adapter.last_send_at + min_gap_seconds` when necessary.
  """
  @spec check(map(), Ecto.Schema.t()) :: :ok | {:defer, DateTime.t(), map()}
  def check(_context, %{min_gap_seconds: nil}), do: :ok
  def check(_context, %{last_send_at: nil}), do: :ok
  def check(_context, %{min_gap_seconds: 0}), do: :ok

  def check(
        context,
        %{last_send_at: %DateTime{} = last_send_at, min_gap_seconds: seconds} = adapter
      )
      when is_integer(seconds) and seconds > 0 do
    defer_until = DateTime.add(last_send_at, seconds, :second)

    if DateTime.compare(defer_until, Clock.now()) == :gt do
      :telemetry.execute([:dripdrop, :policy, :min_gap], %{count: 1}, %{
        step_execution_id: context.execution.id,
        tenant_key: context.execution.tenant_key,
        adapter_id: adapter.id,
        defer_until: defer_until,
        min_gap_seconds: seconds
      })

      {:defer, defer_until,
       %{
         reason: "min_gap",
         adapter_id: adapter.id,
         min_gap_seconds: seconds
       }}
    else
      :ok
    end
  end
end
