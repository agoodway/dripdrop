defmodule DripdropDemo.MockHooks do
  @moduledoc """
  Demo-only HTTP hook server used by seeded DripDrop scenarios.

  This process is intentionally started only in dev/test. Production hosts
  should point DripDrop HTTP hooks at real application endpoints instead.
  """

  use Supervisor

  alias DripdropDemo.MockHooks.{Router, Scores}

  @default_scores %{
    "lead-low" => 40,
    "lead-high" => 85,
    "fixture" => 85
  }

  @doc """
  Starts the demo-only mock HTTP hook supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the child specification for the mock hook supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(_opts) do
    port = Application.fetch_env!(:dripdrop_demo, :mock_hooks_port)

    children = [
      %{
        id: Scores,
        start: {Agent, :start_link, [fn -> @default_scores end, [name: Scores]]}
      },
      {Bandit, plug: Router, port: port, ip: {127, 0, 0, 1}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Builds an absolute URL to a mock-hook endpoint.
  """
  @spec url(String.t()) :: String.t()
  def url(path \\ "") do
    port = Application.fetch_env!(:dripdrop_demo, :mock_hooks_port)
    "http://localhost:#{port}#{path}"
  end

  @doc """
  Sets the deterministic lead score returned for a lead id.
  """
  @spec set_score(String.t(), integer()) :: :ok
  def set_score(lead_id, score) when is_binary(lead_id) and is_integer(score) do
    Agent.update(Scores, &Map.put(&1, lead_id, score))
  end

  @doc """
  Reads the deterministic lead score for a lead id.
  """
  @spec score_for(String.t()) :: integer()
  def score_for(lead_id) do
    Agent.get(Scores, &Map.get(&1, lead_id, 50))
  end

  @doc """
  Resets mock lead scores to the seeded defaults.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(Scores, fn _scores -> @default_scores end)
  end
end

defmodule DripdropDemo.MockHooks.Router do
  @moduledoc false

  use Plug.Router

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:match)
  plug(:dispatch)

  get "/lead-score" do
    lead_id = conn.params["lead_id"] || "fixture"
    score = DripdropDemo.MockHooks.score_for(lead_id)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{lead_id: lead_id, score: score}))
  end

  get "/onboarding/setup-status" do
    setup_complete? = truthy?(conn.params["setup_complete"])
    plan = conn.params["plan"] || "unknown"

    response = %{
      subscriber_id: conn.params["subscriber_id"],
      plan: plan,
      setup_state: if(setup_complete?, do: "complete", else: "incomplete"),
      sms_followup_eligible: setup_complete?,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "demo:onboarding_hooks",
      {"onboarding.setup_status.checked", response}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  post "/crm-update" do
    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "demo:webhooks",
      {"crm-update.received",
       %{
         body: conn.body_params,
         headers: webhook_headers(conn.req_headers),
         method: conn.method,
         path: conn.request_path,
         received_at: DateTime.utc_now()
       }}
    )

    send_resp(conn, 204, "")
  end

  post "/slack-alert" do
    Phoenix.PubSub.broadcast(
      DripdropDemo.PubSub,
      "demo:webhooks",
      {"slack-alert.received",
       %{
         body: conn.body_params,
         headers: webhook_headers(conn.req_headers),
         method: conn.method,
         path: conn.request_path,
         received_at: DateTime.utc_now()
       }}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, ts: DateTime.utc_now() |> DateTime.to_unix()}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp webhook_headers(headers) do
    headers
    |> Enum.filter(fn {key, _value} ->
      key in ["content-type", "webhook-id", "webhook-timestamp", "webhook-signature"]
    end)
    |> Map.new()
  end

  defp truthy?(value), do: to_string(value) in ["true", "1", "yes"]
end
