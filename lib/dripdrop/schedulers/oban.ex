defmodule DripDrop.Schedulers.Oban do
  @moduledoc """
  Scheduler adapter for host applications that use Oban.
  """

  alias DripDrop.Jobs
  alias DripDrop.Scheduler

  @behaviour Scheduler

  @impl Scheduler
  def schedule(%{id: step_execution_id}, scheduled_for) do
    with true <- oban_available?(),
         {:ok, scheduled_at} <- normalize_scheduled_at(scheduled_for),
         job_changeset <- new_job(step_execution_id, scheduled_at),
         {:ok, %{id: job_id}} <- safe_insert(job_changeset) do
      {:ok, job_id}
    else
      false -> {:error, :oban_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # Oban.insert/1 can raise (e.g. `Oban.Registry` not started in a host that
  # has Oban listed as a dep but hasn't supervised it). Convert that to a
  # well-typed error so the dispatch contract is preserved.
  defp safe_insert(job_changeset) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Oban, :insert, [job_changeset])
  rescue
    exception -> {:error, {:oban_runtime, exception}}
  end

  @impl Scheduler
  def cancel(nil), do: :ok

  def cancel(job_id) do
    if Code.ensure_loaded?(Oban) and function_exported?(Oban, :cancel_job, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Oban, :cancel_job, [job_id]) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
        other -> other
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp oban_available? do
    Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Oban.Job) and
      function_exported?(Oban.Job, :new, 2) and function_exported?(Oban, :insert, 1)
  end

  defp new_job(step_execution_id, scheduled_at) do
    args = %{"step_execution_id" => step_execution_id}

    job_opts = [
      worker: Jobs.DispatchStep,
      queue: :dripdrop,
      scheduled_at: scheduled_at
    ]

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Oban.Job, :new, [args, job_opts])
  end

  defp normalize_scheduled_at(%DateTime{} = datetime), do: {:ok, datetime}

  defp normalize_scheduled_at(%NaiveDateTime{} = datetime) do
    DateTime.from_naive(datetime, "Etc/UTC")
  end
end
