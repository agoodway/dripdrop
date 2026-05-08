defmodule DripDrop.TestSupport.PgflowHarness do
  @moduledoc """
  Test harness for running DripDrop dispatch through PgFlow.
  """

  alias Ecto.Adapters.SQL

  @job DripDrop.Jobs.DispatchStep
  @queue "dispatch_step"

  @doc """
  Child spec for starting PgFlow with the DripDrop dispatch job.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    opts =
      Keyword.merge(
        [
          repo: DripDrop.TestRepo,
          jobs: [@job],
          max_concurrency: 1,
          batch_size: 1,
          signal_strategy: :polling,
          min_poll_interval: 50,
          max_poll_interval: 100,
          notify_fallback_interval: 250,
          recovery_interval: 250,
          stale_threshold: 2
        ],
        opts
      )

    Supervisor.child_spec({PgFlow, opts}, id: __MODULE__)
  end

  @doc """
  Waits until the dispatch queue has no queued PgFlow tasks or pgmq messages.
  """
  @spec wait_for_idle(timeout()) :: :ok | :timeout
  def wait_for_idle(timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_idle(deadline)
  end

  defp wait_until_idle(deadline) do
    if idle?() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(50)
        wait_until_idle(deadline)
      end
    end
  end

  defp idle? do
    queued_tasks =
      scalar!(
        "SELECT count(*) FROM pgflow.step_tasks WHERE flow_slug = $1 AND status = 'queued'",
        [@queue]
      )

    queued_messages = scalar!("SELECT count(*) FROM pgmq.q_#{@queue}", [])

    queued_tasks == 0 and queued_messages == 0
  rescue
    Postgrex.Error -> false
  end

  defp scalar!(sql, params) do
    %{rows: [[value]]} = SQL.query!(DripDrop.TestRepo, sql, params)
    value
  end
end
