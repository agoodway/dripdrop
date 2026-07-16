defmodule DripDrop.SequenceReaders do
  @moduledoc """
  Read-only queries for sequences, sequence versions, and steps.

  Complements `DripDrop.SequenceAuthoring`, which owns writes for the same
  aggregates. Sequence reads take an explicit `tenant_key` because a sequence
  `key` is only unique within its tenant scope (or globally, when
  `tenant_key` is `nil`). Sequence version and step reads are looked up by
  id, so they inherit tenant scope implicitly from the row they belong to.
  """

  import Ecto.Query

  alias DripDrop.{Repo, Sequence, SequenceVersion, Step}

  @doc """
  Fetches a sequence by `key` within a tenant scope.

  Pass `nil` for `tenant_key` to look up a global (tenant-less) sequence.
  Returns `nil` when no such sequence has been provisioned.
  """
  @spec get_sequence(binary() | nil, String.t()) :: Ecto.Schema.t() | nil
  def get_sequence(tenant_key, sequence_key) do
    Sequence
    |> where([sequence], sequence.key == ^sequence_key)
    |> where_tenant_scope(tenant_key)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Fetches a sequence's currently active version, or `nil` when none is active.

  A half-provisioned sequence (row created, activation never completed) has
  no active version; callers use this non-raising read to detect that.
  """
  @spec get_active_sequence_version(Ecto.UUID.t()) :: SequenceVersion.t() | nil
  def get_active_sequence_version(sequence_id) do
    SequenceVersion
    |> where([version], version.sequence_id == ^sequence_id)
    |> where([version], version.state == "active")
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Fetches a sequence's currently active version, raising when none is active.
  """
  @spec get_active_sequence_version!(Ecto.UUID.t()) :: SequenceVersion.t()
  def get_active_sequence_version!(sequence_id) do
    case get_active_sequence_version(sequence_id) do
      %SequenceVersion{} = version -> version
      nil -> raise Ecto.NoResultsError, queryable: SequenceVersion
    end
  end

  @doc """
  Returns the highest version number authored for a sequence, or `0` when the
  sequence has no versions yet.

  Useful for computing the next version number when authoring a fresh
  version, so a re-versioned sequence never collides with a lingering draft
  on the unique `(sequence, version)` index.
  """
  @spec max_version_number(Ecto.UUID.t()) :: non_neg_integer()
  def max_version_number(sequence_id) do
    SequenceVersion
    |> where([version], version.sequence_id == ^sequence_id)
    |> select([version], max(version.version))
    |> Repo.one()
    |> case do
      nil -> 0
      number -> number
    end
  end

  @doc """
  Fetches the most recently authored step for a `key` across all of a
  sequence's versions, or `nil` when no version has ever contained that step.

  A step disabled in (or absent from) the active version is recovered from
  the newest prior version that still carries it.
  """
  @spec latest_step_by_key(Ecto.UUID.t(), String.t()) :: Step.t() | nil
  def latest_step_by_key(sequence_id, step_key) do
    Step
    |> join(:inner, [step], version in SequenceVersion,
      on: version.id == step.sequence_version_id
    )
    |> where([step, version], version.sequence_id == ^sequence_id)
    |> where([step, _version], step.key == ^step_key)
    |> order_by([_step, version], desc: version.version)
    |> limit(1)
    |> select([step, _version], step)
    |> Repo.one()
  end

  @doc """
  Lists a sequence version's steps, ordered by their position in the cadence.
  """
  @spec ordered_steps(Ecto.UUID.t()) :: [Step.t()]
  def ordered_steps(version_id) do
    Step
    |> where([step], step.sequence_version_id == ^version_id)
    |> order_by([step], asc: step.position)
    |> Repo.all()
  end

  @doc """
  Maps a sequence version's steps by their `key` (e.g. `"invitation"`).
  """
  @spec steps_by_key(Ecto.UUID.t()) :: %{String.t() => Step.t()}
  def steps_by_key(version_id) do
    version_id
    |> ordered_steps()
    |> Map.new(&{&1.key, &1})
  end

  defp where_tenant_scope(query, nil), do: where(query, [row], is_nil(row.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [row], row.tenant_key == ^tenant_key)
end
