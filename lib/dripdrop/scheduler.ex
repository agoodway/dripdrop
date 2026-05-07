defmodule DripDrop.Scheduler do
  @moduledoc """
  Behaviour for scheduling DripDrop step executions.
  """

  @callback schedule(execution :: term(), scheduled_for :: DateTime.t()) ::
              {:ok, term()} | {:error, term()}

  @callback cancel(job_id :: term()) :: :ok | {:error, term()}

  @backend_modules %{
    "pgflow" => DripDrop.Schedulers.Pgflow,
    "oban" => DripDrop.Schedulers.Oban,
    "test" => DripDrop.Schedulers.Test
  }

  @doc """
  Returns the configured scheduler module.
  """
  @spec configured() :: module()
  def configured, do: Application.get_env(:dripdrop, :scheduler, DripDrop.Schedulers.Pgflow)

  @doc """
  Returns the short name (e.g. "pgflow", "oban") for the configured scheduler.
  Used to populate `step_executions.scheduler_backend` so a later cancel/replay
  routes to the correct backend even if the configured scheduler has been swapped.
  """
  @spec configured_name() :: binary()
  def configured_name, do: name_for_module(configured())

  @doc """
  Resolves a stored scheduler-backend name to its module.
  """
  @spec module_for_backend(binary()) :: {:ok, module()} | {:error, :unknown_backend}
  def module_for_backend(backend) when is_binary(backend) do
    case Map.fetch(@backend_modules, backend) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_backend}
    end
  end

  defp name_for_module(module) do
    @backend_modules
    |> Enum.find_value(fn {name, mod} -> if mod == module, do: name end)
    |> Kernel.||(module |> Module.split() |> List.last() |> String.downcase())
  end
end
