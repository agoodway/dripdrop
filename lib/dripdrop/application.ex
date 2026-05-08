defmodule DripDrop.Application do
  @moduledoc """
  OTP application supervisor for DripDrop runtime services.
  """

  use Application

  alias DripDrop.Policy.BounceComplaintThresholds
  alias DripDrop.{Schedulers, ShortLinks, Vault}

  @impl Application
  def start(_type, _args) do
    children =
      [
        vault_child(),
        DripDrop.Cache,
        DripDrop.AdapterPools.WDRR,
        {Registry, keys: :unique, name: ShortLinks.Registry},
        {Task.Supervisor, name: DripDrop.TaskSupervisor},
        threshold_child(),
        scheduler_child()
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: DripDrop.Supervisor)
  end

  defp vault_child do
    if Code.ensure_loaded?(Vault) do
      Vault
    end
  end

  defp scheduler_child do
    scheduler = Application.get_env(:dripdrop, :scheduler, Schedulers.Pgflow)

    if function_exported?(scheduler, :child_spec, 1) do
      scheduler
    end
  end

  defp threshold_child do
    if Application.get_env(:dripdrop, :repo) &&
         threshold_config(:enabled, true) do
      {BounceComplaintThresholds, threshold_config()}
    end
  end

  defp threshold_config do
    Application.get_env(:dripdrop, :bounce_complaint_thresholds, [])
  end

  defp threshold_config(key, default) do
    case threshold_config() do
      config when is_map(config) -> Map.get(config, to_string(key), Map.get(config, key, default))
      config when is_list(config) -> Keyword.get(config, key, default)
      _config -> default
    end
  end
end
