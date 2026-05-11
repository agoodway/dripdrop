defmodule DripdropDemo.Scenarios.Outbound do
  @moduledoc """
  Demo context for the outbound campaigns scenario. Owns the queries and
  enrollment workflow used by `DripdropDemoWeb.Scenarios.OutboundLive`,
  including pool-member status and threaded message rows.
  """

  import Ecto.Query

  alias DripDrop.{
    AdapterHealth,
    ChannelAdapter,
    Enrollment,
    MessageEvent,
    Sequence,
    Step,
    StepExecution,
    Suppression
  }

  alias DripdropDemo.Repo
  alias DripdropDemo.Scenarios.Outbound.Outcomes

  @sequence_key "outbound-campaigns"
  @pool_name "outbound_pool"
  @tenant_key "demo"
  @daily_cap_default 45
  @min_gap_default 2

  @doc "Default daily cap for outbound demo senders. Must match seeds.exs."
  @spec daily_cap_default() :: pos_integer()
  def daily_cap_default, do: @daily_cap_default

  @doc "Default min-gap seconds for outbound demo senders. Must match seeds.exs."
  @spec min_gap_default() :: pos_integer()
  def min_gap_default, do: @min_gap_default

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
          adapter_provider: String.t() | nil,
          sender_email: String.t() | nil,
          email: String.t() | nil,
          company: String.t() | nil,
          first_name: String.t() | nil,
          outcome: Outcomes.outcome(),
          last_defer: map() | nil
        }

  @type pool_member_row :: %{
          id: String.t(),
          name: String.t(),
          provider: String.t(),
          sender_email: String.t() | nil,
          health_state: atom(),
          daily_cap: integer() | nil,
          effective_cap_today: integer() | nil,
          min_gap_seconds: integer() | nil,
          last_send_at: DateTime.t() | nil,
          paused_until: DateTime.t() | nil,
          paused_reason: String.t() | nil,
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
    with {:ok, _reset} <- reset_capacity_today() do
      case Repo.one(from(sequence in Sequence, where: sequence.key == ^@sequence_key, limit: 1)) do
        nil -> {:error, :seeded_outbound_sequence_missing}
        sequence -> enroll_all(sequence)
      end
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
      adapter_provider: adapter.provider,
      sender_email: adapter.credentials,
      email: fragment("?->>'email'", enrollment.data),
      company: fragment("?->>'company'", enrollment.data),
      first_name: fragment("?->>'first_name'", enrollment.data)
    })
    |> Repo.all()
    |> Enum.map(&put_outcome_state/1)
    |> Enum.sort_by(&prospect_index(&1.first_name))
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

  @doc """
  Resets the demo sender pool's replay pressure.

  DripDrop computes sender capacity from today's `sent` message events. For the
  public demo, we preserve sent event rows but move today's pool sends outside
  the current day. We also remove demo-only bounce/unsubscribe/reply artifacts
  and restore the seeded sender limits so the scenario can be replayed without
  reseeding the whole database.
  """
  @spec reset_capacity_today() ::
          {:ok,
           %{
             sent_events: non_neg_integer(),
             outcome_events: non_neg_integer(),
             suppressions: non_neg_integer(),
             adapters: non_neg_integer()
           }}
          | {:error, term()}
  def reset_capacity_today do
    adapter_ids = outbound_pool_adapter_ids()

    if adapter_ids == [] do
      {:error, :outbound_pool_missing}
    else
      reset_at =
        Date.utc_today()
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        |> DateTime.add(-1, :second)

      Repo.transaction(fn ->
        {sent_events, _rows} =
          MessageEvent
          |> where([event], event.tenant_key == ^@tenant_key)
          |> where([event], event.adapter_id in ^adapter_ids)
          |> where([event], event.event_type == "sent")
          |> where([event], event.occurred_at >= ^day_start())
          |> Repo.update_all(set: [occurred_at: reset_at])

        {outcome_events, _rows} =
          MessageEvent
          |> where([event], event.tenant_key == ^@tenant_key)
          |> where([event], event.provider == "demo")
          |> where([event], event.event_type in ["bounced", "replied", "unsubscribed"])
          |> Repo.delete_all()

        {suppressions, _rows} =
          Suppression
          |> where([suppression], suppression.tenant_key == ^@tenant_key)
          |> where([suppression], suppression.channel == "email")
          |> where([suppression], suppression.recipient_normalized in ^prospect_emails())
          |> where([suppression], suppression.source == "demo-button")
          |> Repo.delete_all()

        adapters =
          ChannelAdapter
          |> where([adapter], adapter.id in ^adapter_ids)
          |> Repo.all()
          |> Enum.map(&reset_adapter_capacity!/1)
          |> length()

        %{
          sent_events: sent_events,
          outcome_events: outcome_events,
          suppressions: suppressions,
          adapters: adapters
        }
      end)
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

  @doc "Returns the latest deferred message event metadata for one enrollment."
  @spec latest_defer(String.t()) :: map() | nil
  def latest_defer(enrollment_id) when is_binary(enrollment_id) do
    MessageEvent
    |> join(:inner, [event], execution in StepExecution,
      on: execution.id == event.step_execution_id
    )
    |> where([event, execution], execution.enrollment_id == ^enrollment_id)
    |> where([event], event.event_type == "deferred")
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> select([event], event.event_data)
    |> limit(1)
    |> Repo.one()
  end

  def latest_defer(_enrollment_id), do: nil

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

  defp outbound_pool_adapter_ids do
    case find_outbound_pool() do
      nil ->
        []

      pool ->
        pool
        |> DripDrop.list_pool_members()
        |> Enum.map(& &1.adapter.id)
    end
  end

  defp reset_adapter_capacity!(%ChannelAdapter{} = adapter) do
    config = Map.drop(adapter.config || %{}, ["paused_until", "paused_reason"])

    adapter
    |> ChannelAdapter.changeset(%{
      active: true,
      health_state: :active,
      resting_until: nil,
      last_send_at: nil,
      daily_cap: @daily_cap_default,
      ramp_started_at: nil,
      ramp_increment: nil,
      ramp_floor: nil,
      min_gap_seconds: @min_gap_default,
      config: config
    })
    |> Repo.update!()
  end

  defp pool_member_row(%{adapter: %ChannelAdapter{} = adapter}) do
    %{
      id: adapter.id,
      name: adapter.name,
      provider: adapter.provider,
      sender_email: mailbox_email(adapter.credentials),
      health_state: adapter.health_state,
      daily_cap: adapter.daily_cap,
      effective_cap_today: AdapterHealth.effective_cap_today(adapter),
      min_gap_seconds: adapter.min_gap_seconds,
      last_send_at: adapter.last_send_at,
      paused_until: paused_until(adapter),
      paused_reason: paused_reason(adapter),
      sent_today: sent_today(adapter.id)
    }
  end

  defp put_outcome_state(row) do
    row
    |> Map.put(:outcome, Outcomes.for_first_name(row.first_name))
    |> Map.update!(:sender_email, &mailbox_email/1)
    |> Map.put(:last_defer, latest_defer(row.id))
  end

  defp mailbox_email(%{"from" => from}) when is_binary(from), do: parse_mailbox(from)
  defp mailbox_email(%{from: from}) when is_binary(from), do: parse_mailbox(from)
  defp mailbox_email(_credentials), do: nil

  defp parse_mailbox(from) do
    case Regex.run(~r/<([^>]+)>/, from) do
      [_match, email] -> email
      _no_match -> from
    end
  end

  defp prospect_index(first_name) do
    @prospects
    |> Enum.find_index(fn {name, _company, _email} -> name == first_name end)
    |> case do
      nil -> 999
      index -> index
    end
  end

  defp prospect_emails do
    Enum.map(@prospects, fn {_name, _company, email} -> email end)
  end

  defp paused_until(%ChannelAdapter{config: %{"paused_until" => value}}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp paused_until(_adapter), do: nil

  defp paused_reason(%ChannelAdapter{config: %{"paused_reason" => reason}}), do: reason
  defp paused_reason(_adapter), do: nil

  defp sent_today(adapter_id) do
    MessageEvent
    |> where([event], event.adapter_id == ^adapter_id)
    |> where([event], event.event_type == "sent")
    |> where([event], event.occurred_at >= ^day_start())
    |> Repo.aggregate(:count)
  end

  defp day_start do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
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
