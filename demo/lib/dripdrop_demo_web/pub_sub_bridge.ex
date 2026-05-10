defmodule DripdropDemoWeb.PubSubBridge do
  @moduledoc """
  Republishes DripDrop telemetry into Phoenix PubSub topics for demo LiveViews.

  Lives in the supervisor tree (not under `live/`) because telemetry handlers
  fire in the *emitting* process, not in this GenServer. The GenServer exists
  only to own attach/detach lifecycle around `init/2` and `terminate/2`.
  """

  use GenServer
  require Logger

  @handler_id {__MODULE__, :dripdrop}

  @doc """
  Starts the bridge. Attaches a single global telemetry handler covering every
  event listed in `DripDrop.Telemetry.events/0` and rebroadcasts each event
  through `DripdropDemo.PubSub`.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :telemetry.attach_many(
      @handler_id,
      DripDrop.Telemetry.events(),
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    message = {:dripdrop_event, event, measurements, metadata}

    Phoenix.PubSub.broadcast(DripdropDemo.PubSub, "dripdrop:events", message)

    metadata
    |> Map.get(:enrollment_id)
    |> broadcast("enrollment", message)

    metadata
    |> Map.get(:adapter_id)
    |> broadcast("adapter", message)

    :ok
  rescue
    error ->
      Logger.warning(
        "DripdropDemoWeb.PubSubBridge handler failed:\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp broadcast(nil, _prefix, _message), do: :ok

  defp broadcast(id, prefix, message) do
    Phoenix.PubSub.broadcast(DripdropDemo.PubSub, "#{prefix}:#{id}", message)
  end
end
