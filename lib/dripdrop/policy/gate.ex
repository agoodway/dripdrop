defmodule DripDrop.Policy.Gate do
  @moduledoc """
  First dispatch policy check.
  """

  alias DripDrop.Suppressions

  @doc """
  Skips dispatch when the recipient is suppressed for the channel.
  """
  @spec check(map()) :: :ok | {:skip, :suppressed}
  def check(%{channel: channel, recipient: recipient} = context) when is_binary(recipient) do
    tenant_key = Map.get(context, :tenant_key)

    if Suppressions.suppressed?(channel, recipient, tenant_key) do
      :telemetry.execute([:dripdrop, :policy, :suppressed], %{count: 1}, %{
        channel: channel,
        tenant_key: tenant_key
      })

      {:skip, :suppressed}
    else
      :ok
    end
  end

  def check(_context), do: :ok
end
