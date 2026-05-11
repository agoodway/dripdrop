defmodule DripdropDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias DripDrop.Channels
  alias DripDrop.Jobs.{CronTick, DispatchStep}
  alias DripdropDemo.Channels.Telegram.Local, as: LocalTelegram
  alias DripdropDemo.Jobs.PruneSequenceRuns

  @start_mock_hooks? Application.compile_env(:dripdrop_demo, :start_mock_hooks?, false)

  @impl true
  def start(_type, _args) do
    :ok = register_demo_channels()

    children =
      [
        DripdropDemo.Repo,
        {PgFlow,
         repo: DripdropDemo.Repo,
         jobs: [DispatchStep, CronTick, PruneSequenceRuns],
         signal_strategy: :notify,
         notify_throttle_ms: 50,
         notify_fallback_interval: 250},
        DripdropDemoWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:dripdrop_demo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DripdropDemo.PubSub},
        DripdropDemoWeb.PubSubBridge,
        mock_hooks_child(),
        DripdropDemoWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :rest_for_one, name: DripdropDemo.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = result ->
        log_startup_check()
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp mock_hooks_child do
    if @start_mock_hooks? and Code.ensure_loaded?(DripdropDemo.MockHooks) do
      DripdropDemo.MockHooks
    end
  end

  defp log_startup_check do
    case DripDrop.startup_check() do
      :ok -> :ok
      {:error, errors} -> Logger.warning("DripDrop startup check reported: #{inspect(errors)}")
    end
  end

  @doc """
  Registers demo-only channel providers with the DripDrop channel registry.

  Called from the application start callback and also from
  `DripdropDemo.Release.seed/0` so seeds can insert adapters that reference
  these providers without booting the full app.
  """
  def register_demo_channels do
    Channels.register(:telegram, :local, LocalTelegram)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DripdropDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
