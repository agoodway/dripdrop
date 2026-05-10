defmodule DripdropDemo.Scenarios.Outbound do
  @moduledoc """
  Demo context for the outbound campaigns scenario. Owns the queries and
  enrollment workflow used by `DripdropDemoWeb.Scenarios.OutboundLive`,
  including pool-member status and threaded message rows.
  """

  import Ecto.Query

  alias DripDrop.{ChannelAdapter, Enrollment, MessageEvent, Sequence, Step, StepExecution}
  alias DripdropDemo.Repo

  @sequence_key "outbound-campaigns"
  @pool_name "outbound_pool"
  @tenant_key "demo"

  @prospects [
    {"Mia", "Northstar SaaS", "mia@northstar.example"},
    {"Jordan", "Atlas Metrics", "jordan@atlas.example"},
    {"Priya", "SignalOps", "priya@signalops.example"},
    {"Eli", "Runway Data", "eli@runway.example"},
    {"Nora", "StackPilot", "nora@stackpilot.example"},
    {"Theo", "OpsCanvas", "theo@opscanvas.example"},
    {"Avery", "MetricForge", "avery@metricforge.example"},
    {"Quinn", "LaunchGrid", "quinn@launchgrid.example"}
  ]

  @type enrollment_row :: %{
          id: String.t(),
          state: String.t(),
          adapter_id: String.t() | nil,
          adapter_name: String.t() | nil,
          email: String.t() | nil,
          company: String.t() | nil,
          first_name: String.t() | nil
        }

  @type pool_member_row :: %{
          id: String.t(),
          name: String.t(),
          health_state: atom(),
          daily_cap: integer() | nil,
          min_gap_seconds: integer() | nil,
          sent_today: non_neg_integer()
        }

  @type thread_row :: %{
          step_key: String.t(),
          state: String.t(),
          executed_at: DateTime.t() | nil,
          out_message_id: String.t() | nil,
          recipient: String.t() | nil,
          payload: map() | nil,
          response: map() | nil,
          in_reply_to: String.t() | nil,
          references: String.t()
        }

  @doc "Returns true when the seeded outbound campaigns sequence is present."
  @spec sequence_available?() :: boolean()
  def sequence_available? do
    Repo.exists?(from(sequence in Sequence, where: sequence.key == ^@sequence_key))
  end

  @doc """
  Enrolls the eight canonical demo prospects against the seeded outbound
  sequence. Halts on the first error.
  """
  @spec enroll_prospects() :: {:ok, [DripDrop.Enrollment.t()]} | {:error, term()}
  def enroll_prospects do
    case Repo.one(from(sequence in Sequence, where: sequence.key == ^@sequence_key, limit: 1)) do
      nil -> {:error, :seeded_outbound_sequence_missing}
      sequence -> enroll_all(sequence)
    end
  end

  @doc "Lists enrollment projection rows by id, joined with their pinned adapter."
  @spec list_enrollments([String.t()]) :: [enrollment_row()]
  def list_enrollments([]), do: []

  def list_enrollments(ids) do
    Enrollment
    |> where([enrollment], enrollment.id in ^ids)
    |> join(:left, [enrollment], adapter in ChannelAdapter,
      on: adapter.id == enrollment.adapter_id
    )
    |> order_by([enrollment], asc: enrollment.inserted_at)
    |> select([enrollment, adapter], %{
      id: enrollment.id,
      state: enrollment.state,
      adapter_id: enrollment.adapter_id,
      adapter_name: adapter.name,
      email: fragment("?->>'email'", enrollment.data),
      company: fragment("?->>'company'", enrollment.data),
      first_name: fragment("?->>'first_name'", enrollment.data)
    })
    |> Repo.all()
  end

  @doc "Lists pool member projection rows for the seeded outbound campaigns pool."
  @spec list_pool_members() :: [pool_member_row()]
  def list_pool_members do
    case find_outbound_pool() do
      nil ->
        []

      pool ->
        pool
        |> DripDrop.list_pool_members()
        |> Enum.map(&pool_member_row/1)
    end
  end

  @doc "Returns the threaded message rows for a given enrollment, ordered by step."
  @spec latest_thread_rows(String.t() | nil) :: [thread_row()]
  def latest_thread_rows(nil), do: []

  def latest_thread_rows(enrollment_id) do
    StepExecution
    |> where([execution], execution.enrollment_id == ^enrollment_id)
    |> join(:left, [execution], step in Step, on: step.id == execution.step_id)
    |> order_by([execution, step], asc: step.position, asc: execution.inserted_at)
    |> select([execution, step], %{
      step_key: step.key,
      state: execution.state,
      executed_at: execution.executed_at,
      out_message_id: execution.out_message_id,
      recipient: execution.recipient,
      payload: execution.payload,
      response: execution.response
    })
    |> Repo.all()
    |> append_thread_headers()
  end

  defp enroll_all(sequence) do
    @prospects
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &enroll_prospect(&1, &2, sequence))
    |> finalize_enrollments()
  end

  defp enroll_prospect({{first_name, company, email}, index}, {:ok, acc}, sequence) do
    attrs = %{
      sequence_id: sequence.id,
      subscriber_type: "prospect",
      subscriber_id: "goodway-prospect-#{index}-#{System.unique_integer([:positive])}",
      tenant_key: sequence.tenant_key,
      data: %{
        "first_name" => first_name,
        "company" => company,
        "email" => email,
        "interest" => "Elixir software development consulting"
      }
    }

    case DripDrop.enroll(attrs) do
      {:ok, enrollment} -> {:cont, {:ok, [enrollment | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_enrollments({:ok, enrollments}), do: {:ok, Enum.reverse(enrollments)}
  defp finalize_enrollments(error), do: error

  defp find_outbound_pool do
    %{tenant_key: @tenant_key}
    |> DripDrop.list_adapter_pools()
    |> Enum.find(&(&1.name == @pool_name))
  end

  defp pool_member_row(%{adapter: %ChannelAdapter{} = adapter}) do
    %{
      id: adapter.id,
      name: adapter.name,
      health_state: adapter.health_state,
      daily_cap: adapter.daily_cap,
      min_gap_seconds: adapter.min_gap_seconds,
      sent_today: sent_today(adapter.id)
    }
  end

  defp sent_today(adapter_id) do
    today = Date.utc_today()

    MessageEvent
    |> where([event], event.adapter_id == ^adapter_id)
    |> where([event], event.event_type == "sent")
    |> where([event], fragment("?::date", event.occurred_at) == ^today)
    |> Repo.aggregate(:count)
  end

  defp append_thread_headers(rows) do
    rows
    |> Enum.map_reduce([], fn row, previous_message_ids ->
      row =
        row
        |> Map.put(:in_reply_to, List.last(previous_message_ids))
        |> Map.put(:references, Enum.join(previous_message_ids, " "))

      previous_message_ids =
        if row.out_message_id,
          do: previous_message_ids ++ [row.out_message_id],
          else: previous_message_ids

      {row, previous_message_ids}
    end)
    |> elem(0)
  end
end
