defmodule DripDrop.ShortLinks do
  @moduledoc """
  Context for persisted short-link records.

  The rewriting pipeline stays focused on URL parsing and provider calls while
  this context owns the DripDrop schema interactions for idempotent short-link
  lookup and persistence.
  """

  alias DripDrop.{Repo, ShortLink}
  alias DripDrop.ShortLinks.Result

  @doc """
  Returns an existing short-link row for an idempotency key.
  """
  @spec get_by_idempotency_key(binary()) :: Ecto.Schema.t() | nil
  def get_by_idempotency_key(idempotency_key) when is_binary(idempotency_key) do
    Repo.repo!().get_by(ShortLink, idempotency_key: idempotency_key)
  end

  @doc """
  Persists a provider result for a shortened URL.
  """
  @spec persist_result(map()) :: :ok | {:error, map()}
  def persist_result(attrs) when is_map(attrs) do
    %ShortLink{}
    |> ShortLink.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, %{kind: :permanent, reason: changeset}}
    end
  end

  @doc """
  Returns true when a provider result should not write a short-link row.
  """
  @spec skipped_result?(Result.t()) :: boolean()
  def skipped_result?(%Result{response: %{skipped: true}}), do: true
  def skipped_result?(_result), do: false
end
