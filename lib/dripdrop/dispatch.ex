defmodule DripDrop.Dispatch do
  @moduledoc """
  Dispatch administration helpers.
  """

  alias DripDrop.Dispatch.Idempotency
  alias DripDrop.{Repo, Scheduler, StepExecution}
  alias Ecto.Changeset
  alias Ecto.Multi

  @doc """
  Replays a failed step execution by creating a new attempt window and schedule.
  """
  @spec replay(Ecto.UUID.t()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  def replay(step_execution_id) do
    execution = Repo.get!(StepExecution, step_execution_id)
    attempt_window = execution.attempt_window + 1

    idempotency_key =
      Idempotency.key(
        execution.enrollment_id,
        execution.step_id,
        execution.scheduled_for,
        attempt_window
      )

    Multi.new()
    |> Multi.update(:execution, replay_changeset(execution, attempt_window, idempotency_key))
    |> Multi.run(:schedule, fn _repo, %{execution: execution} ->
      Scheduler.configured().schedule(execution, execution.scheduled_for)
    end)
    |> Multi.update(:scheduled_execution, fn %{execution: execution, schedule: job_id} ->
      StepExecution.changeset(execution, %{
        scheduler_job_id: job_id_to_string(job_id),
        scheduler_backend: Scheduler.configured_name()
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{scheduled_execution: execution}} -> {:ok, execution}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp replay_changeset(
         %StepExecution{state: "failed"} = execution,
         attempt_window,
         idempotency_key
       ) do
    StepExecution.changeset(execution, %{
      state: "scheduled",
      attempt_window: attempt_window,
      idempotency_key: idempotency_key,
      retry_count: 0,
      error_message: nil,
      failed_at: nil
    })
  end

  defp replay_changeset(%StepExecution{} = execution, _attempt_window, _idempotency_key) do
    execution
    |> Changeset.change()
    |> Changeset.add_error(:state, "must be failed to replay")
  end

  defp job_id_to_string(job_id) when is_binary(job_id), do: job_id
  defp job_id_to_string(job_id) when is_integer(job_id), do: Integer.to_string(job_id)
  defp job_id_to_string(job_id), do: inspect(job_id)
end
