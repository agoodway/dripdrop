defmodule DripDrop.Concurrency.AdapterLock do
  @moduledoc """
  Per-adapter Postgres transaction-scoped advisory lock for outbound dispatch.

  Wraps the outbound deliver path so cap-gate evaluation, state transitions, the
  actual provider send, and counter writes happen serially per adapter. Two
  concurrent workers targeting the same adapter cannot both pass `MinGap`,
  `RampCap`, and `SubCap` and burst past their thresholds; the loser receives
  `:locked` and the dispatch path defers with `"adapter_busy"`.

  Lifecycle dispatch is unaffected — only `deliver_outbound/2` calls this.
  """

  alias DripDrop.Repo

  @doc """
  Runs `fun` inside a transaction holding `pg_try_advisory_xact_lock` keyed by
  the adapter's id. Returns `{:ok, result}` if the lock was acquired and `fun`
  completed; `:locked` if another worker holds the lock right now; or
  `{:error, reason}` for DB errors.
  """
  @spec with_lock(Ecto.Schema.t(), (-> term())) :: {:ok, term()} | :locked | {:error, term()}
  def with_lock(%{id: adapter_id}, fun) when is_function(fun, 0) do
    repo = Repo.repo!()
    key = "dripdrop:adapter:#{adapter_id}"

    repo
    |> run_locked(key, fun)
    |> handle_result()
  end

  defp run_locked(repo, key, fun) do
    repo.transaction(fn -> acquire_and_run(repo, key, fun) end)
  end

  defp acquire_and_run(repo, key, fun) do
    case Repo.query("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [key]) do
      {:ok, %{rows: [[true]]}} -> fun.()
      {:ok, %{rows: [[false]]}} -> repo.rollback(:locked)
      {:error, reason} -> repo.rollback({:db_error, reason})
    end
  end

  defp handle_result({:ok, result}), do: {:ok, result}
  defp handle_result({:error, :locked}), do: :locked
  defp handle_result({:error, {:db_error, reason}}), do: {:error, reason}
  defp handle_result({:error, other}), do: {:error, other}
end
