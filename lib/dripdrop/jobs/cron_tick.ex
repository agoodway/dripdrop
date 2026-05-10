defmodule DripDrop.Jobs.CronTick do
  @moduledoc """
  Seeds due cron-driven steps on each scheduler tick.
  """

  require Logger

  import Ecto.Query

  alias DripDrop.{Clock, Repo, Step, Timing}
  alias DripDrop.Dispatch.Steps, as: DispatchSteps

  use PgFlow.Job

  @job queue: :cron_tick, max_attempts: 1, timeout: 60

  perform :tick do
    fn input, _ctx ->
      __MODULE__.perform(input)
      %{"status" => "ok"}
    end
  end

  import PgFlow.Job, except: [perform: 1, perform: 2]

  @doc """
  Finds cron steps due in the current tick window and seeds their executions.

  Per-step failures are logged and emitted as telemetry; remaining steps in
  the same tick continue. Returns `:ok` always for the worker contract; an
  `errors` count and detail list are included in telemetry metadata.
  """
  @spec perform(map()) :: :ok
  def perform(_input) do
    now = Clock.now()
    from = Clock.shift(now, -60)

    {ok_count, errors} =
      Step
      |> where([step], step.active)
      |> where([step], fragment("?->>'type' = 'cron'", step.timing))
      |> Repo.all()
      |> Enum.reduce({0, []}, fn step, {ok_count, errors} ->
        case maybe_seed_step(step, from, now) do
          :ok ->
            {ok_count + 1, errors}

          {:error, reason} ->
            Logger.error(
              "[dripdrop] CronTick.maybe_seed_step failed step=#{step.id}: #{inspect(reason)}"
            )

            {ok_count, [{step.id, reason} | errors]}
        end
      end)

    :telemetry.execute(
      [:dripdrop, :jobs, :cron_tick, :tick],
      %{processed: ok_count, errors: length(errors)},
      %{errors: errors}
    )

    :ok
  end

  defp maybe_seed_step(step, from, now) do
    case Timing.calculate_next_run(step.timing, from) do
      {:ok, %DateTime{} = scheduled_at} ->
        if DateTime.compare(scheduled_at, now) in [:lt, :eq] do
          seed_step(step, DateTime.truncate(scheduled_at, :second))
        else
          :ok
        end

      _not_due ->
        :ok
    end
  end

  defp seed_step(step, scheduled_for) do
    with {:ok, _executions} <- DispatchSteps.seed_for_step(step, scheduled_for) do
      :ok
    end
  end
end
