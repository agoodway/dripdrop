defmodule DripDrop.Ingest.Correlation do
  @moduledoc """
  Shared message-event correlation queries.
  """

  import Ecto.Query

  alias DripDrop.{Repo, StepExecution}

  @doc """
  Finds a step execution by RFC outbound Message-ID candidates.
  """
  @spec by_out_message_id(map(), [binary()]) :: Ecto.Schema.t() | nil
  def by_out_message_id(_normalized, []), do: nil

  def by_out_message_id(normalized, ids) do
    StepExecution
    |> where([execution], execution.out_message_id in ^ids)
    |> where([execution], execution.channel == ^normalized.channel)
    |> where_tenant_match(normalized.tenant_key)
    |> newest()
    |> Repo.one()
  end

  @doc """
  Finds a step execution by provider-specific message id.
  """
  @spec by_provider_message_id(map()) :: Ecto.Schema.t() | nil
  def by_provider_message_id(%{provider_message_id: nil}), do: nil

  def by_provider_message_id(normalized) do
    StepExecution
    |> where([execution], execution.provider_message_id == ^normalized.provider_message_id)
    |> where([execution], execution.channel == ^normalized.channel)
    |> where_tenant_match(normalized.tenant_key)
    |> newest()
    |> Repo.one()
  end

  defp newest(query) do
    query
    |> order_by([execution], desc: execution.inserted_at)
    |> limit(1)
  end

  defp where_tenant_match(query, nil),
    do: where(query, [execution], is_nil(execution.tenant_key))

  defp where_tenant_match(query, tenant_key),
    do: where(query, [execution], execution.tenant_key == ^tenant_key)
end
