defmodule DripDrop.Suppressions do
  @moduledoc """
  Normalize, create, and query channel suppressions.
  """

  import Ecto.Query

  alias DripDrop.{Clock, Recipients, Repo, Suppression}

  @spec suppress(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Upserts a normalized suppression row for a channel recipient.
  """
  def suppress(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    %Suppression{}
    |> Suppression.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          reason: attrs.reason,
          source: attrs.source,
          metadata: attrs.metadata,
          updated_at: Clock.now()
        ]
      ],
      conflict_target: conflict_target(attrs.tenant_key),
      returning: true
    )
  end

  defp conflict_target(nil) do
    {:unsafe_fragment, ~s|("channel", "recipient_normalized") WHERE tenant_key IS NULL|}
  end

  defp conflict_target(_tenant_key) do
    {:unsafe_fragment,
     ~s|("tenant_key", "channel", "recipient_normalized") WHERE tenant_key IS NOT NULL|}
  end

  @spec suppressed?(atom() | binary(), binary(), binary() | nil) :: boolean()
  @doc """
  Returns true when a normalized recipient is suppressed for the tenant scope.
  """
  def suppressed?(channel, recipient, tenant_key \\ nil) do
    recipient_normalized = normalize(channel, recipient)
    channel = to_string(channel)

    Suppression
    |> where([suppression], suppression.channel == ^channel)
    |> where([suppression], suppression.recipient_normalized == ^recipient_normalized)
    |> where_tenant(tenant_key)
    |> limit(1)
    |> Repo.one()
    |> is_nil()
    |> Kernel.not()
  end

  @spec normalize(atom() | binary(), binary()) :: binary()
  @doc """
  Normalizes a recipient for suppression matching.
  """
  def normalize(channel, recipient), do: Recipients.normalize(channel, recipient)

  defp normalize_attrs(attrs) do
    channel = Map.get(attrs, :channel) || Map.get(attrs, "channel")
    recipient = Map.get(attrs, :recipient) || Map.get(attrs, "recipient")

    %{
      tenant_key: Map.get(attrs, :tenant_key) || Map.get(attrs, "tenant_key"),
      channel: to_string(channel),
      recipient: recipient,
      recipient_normalized:
        Map.get(attrs, :recipient_normalized) || Map.get(attrs, "recipient_normalized") ||
          normalize(channel, recipient),
      reason: to_string(Map.get(attrs, :reason) || Map.get(attrs, "reason")),
      source: Map.get(attrs, :source) || Map.get(attrs, "source"),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    }
  end

  defp where_tenant(query, nil) do
    where(query, [suppression], is_nil(suppression.tenant_key))
  end

  defp where_tenant(query, tenant_key) do
    where(
      query,
      [suppression],
      is_nil(suppression.tenant_key) or suppression.tenant_key == ^tenant_key
    )
  end
end
