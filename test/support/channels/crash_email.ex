defmodule DripDrop.TestSupport.Channels.CrashEmail do
  @moduledoc """
  Test-only email channel used by PgFlow chaos integration tests.
  """

  @behaviour DripDrop.Channel

  @impl DripDrop.Channel
  def validate_credentials(_credentials), do: :ok

  @impl DripDrop.Channel
  def webhook_routes(_adapter), do: []

  @impl DripDrop.Channel
  def verify_signature(_adapter, _request), do: :ok

  @impl DripDrop.Channel
  def deliver(_step, _enrollment, adapter) do
    agent = adapter.config |> Map.fetch!("agent_name") |> String.to_existing_atom()
    mode = Map.get(adapter.config || %{}, "crash_mode", "none")
    count = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)
    message_id = "msg-#{count}"

    case {mode, count} do
      {"before_success", 1} ->
        Process.exit(self(), :kill)

      {"after_success", 1} ->
        Process.exit(self(), :kill)

      _other ->
        {:ok, %{provider_message_id: message_id, response: %{call_count: count}}}
    end
  end
end
