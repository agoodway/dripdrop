defmodule DripDrop.Schedulers.Pgflow do
  @moduledoc """
  Scheduler adapter backed by PgFlow.
  """

  alias DripDrop.Jobs
  alias DripDrop.Scheduler

  @behaviour Scheduler

  @impl Scheduler
  def schedule(%{id: step_execution_id}, scheduled_for) do
    case ensure_pgflow_available() do
      :ok -> enqueue_with_delay(step_execution_id, scheduled_for)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Scheduler
  def cancel(nil), do: :ok

  def cancel(job_id) do
    if Code.ensure_loaded?(PgFlow) and function_exported?(PgFlow, :cancel, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PgFlow, :cancel, [job_id]) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      :telemetry.execute(
        [:dripdrop, :scheduler, :pgflow, :cancel_unsupported],
        %{count: 1},
        %{job_id: job_id}
      )

      :ok
    end
  end

  defp ensure_pgflow_available do
    if Code.ensure_loaded?(PgFlow) and function_exported?(PgFlow, :enqueue_at, 3) do
      :ok
    else
      {:error, :pgflow_unavailable}
    end
  end

  defp enqueue_with_delay(step_execution_id, scheduled_for) do
    input = %{
      "step_execution_id" => step_execution_id,
      "scheduled_for" => DateTime.to_iso8601(scheduled_for)
    }

    PgFlow.enqueue_at(Jobs.DispatchStep, input, scheduled_for)
  end
end
