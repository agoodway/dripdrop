defmodule DripDrop.Suppression do
  @moduledoc """
  A normalized do-not-send record for a channel recipient.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @channels ~w(email sms webhook slack telegram whatsapp)
  @reasons ~w(unsubscribe bounce complaint manual provider_block)

  schema "suppressions" do
    field(:tenant_key, :string)
    field(:channel, :string)
    field(:recipient, :string)
    field(:recipient_normalized, :string)
    field(:reason, :string)
    field(:source, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for normalized suppression rows.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [
      :tenant_key,
      :channel,
      :recipient,
      :recipient_normalized,
      :reason,
      :source,
      :metadata
    ])
    |> validate_required([:channel, :recipient, :recipient_normalized, :reason])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:reason, @reasons)
    |> unique_constraint(:recipient_normalized, name: :suppressions_tenant_recipient_idx)
    |> unique_constraint(:recipient_normalized, name: :suppressions_global_recipient_idx)
  end
end
