defmodule DripDrop.Schedulers.Test do
  @moduledoc """
  In-memory scheduler adapter used by the DripDrop test suite.
  """

  alias DripDrop.Scheduler

  @behaviour Scheduler

  @impl Scheduler
  def schedule(%{id: id}, _scheduled_for), do: {:ok, {:test_job, id}}

  @impl Scheduler
  def cancel(_job_id), do: :ok
end
