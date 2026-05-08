defmodule DripDrop.IntegrationCase do
  @moduledoc """
  Test case for integration tests that exercise the real PgFlow scheduler.

  Unlike `DripDrop.DataCase`, this case does not use the Ecto SQL sandbox.
  PgFlow workers run in separate processes and need ordinary pooled
  connections against the shared Docker database.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias ExUnit.AssertionError

  @dripdrop_tables ~w(
    message_events
    short_links
    suppressions
    step_executions
    events
    enrollments
    conditions
    step_transitions
    steps
    http_hooks
    sequence_versions
    channel_adapters
    sequences
  )

  @pgflow_runtime_tables ~w(
    step_tasks
    step_states
    runs
    workers
  )

  using do
    quote do
      use ExUnit.Case, async: false

      alias DripDrop.TestRepo

      import Ecto
      import Ecto.Query
      import DripDrop.IntegrationCase
    end
  end

  setup_all do
    Sandbox.mode(DripDrop.TestRepo, :auto)
    cleanup!()

    on_exit(fn ->
      cleanup!()
      Sandbox.mode(DripDrop.TestRepo, :manual)
    end)

    :ok
  end

  setup do
    cleanup!()
    on_exit(&cleanup!/0)
    :ok
  end

  @doc """
  Retries an assertion function until it succeeds or the timeout expires.
  """
  @spec eventually((-> term()), keyword()) :: term()
  def eventually(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    eventually(fun, interval, deadline, nil)
  end

  @doc """
  Truncates DripDrop domain tables and PgFlow runtime tables.
  """
  @spec cleanup!() :: :ok
  def cleanup! do
    truncate("dripdrop", @dripdrop_tables)
    truncate("pgflow", @pgflow_runtime_tables)
    truncate_queue("dispatch_step")
    :ok
  end

  defp eventually(fun, interval, deadline, _last_error) do
    fun.()
  rescue
    error in [AssertionError, MatchError] ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise(error, __STACKTRACE__)
      else
        Process.sleep(interval)
        eventually(fun, interval, deadline, error)
      end
  end

  defp truncate(schema, tables) do
    qualified = Enum.map_join(tables, ", ", &~s("#{schema}"."#{&1}"))

    SQL.query!(DripDrop.TestRepo, "TRUNCATE #{qualified} RESTART IDENTITY CASCADE", [])
    :ok
  end

  defp truncate_queue(queue_name) do
    SQL.query!(
      DripDrop.TestRepo,
      "TRUNCATE TABLE pgmq.q_#{queue_name}, pgmq.a_#{queue_name} RESTART IDENTITY",
      []
    )
  rescue
    Postgrex.Error -> :ok
  end
end
