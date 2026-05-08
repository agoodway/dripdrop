defmodule DripDrop.Inbound do
  @moduledoc """
  Host-callable inbound email ingestion.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias DripDrop.{
    ChannelAdapter,
    Clock,
    Event,
    MessageEvent,
    OnReply,
    Redact,
    Repo,
    StepExecution
  }

  alias DripDrop.Ingest.Correlation

  @required_keys [:from, :to, :received_at]
  @optional_keys [
    :message_id,
    :in_reply_to,
    :references,
    :subject,
    :body_text,
    :body_html,
    :headers,
    :intent,
    :intent_data
  ]
  @allowed_keys @required_keys ++ @optional_keys

  @doc """
  Ingests a normalized inbound message from host-owned inbox infrastructure.

  Requires a non-nil `:message_id` in the normalized payload — at-least-once
  delivery from IMAP/Graph/Gmail Watch is dedup'd by `(provider, message_id)`.
  Returns `{:error, :no_message_id}` for messages that lack a Message-ID.
  """
  @spec ingest_inbound_message(Ecto.UUID.t() | map(), map()) :: :ok | {:error, term()}
  def ingest_inbound_message(adapter_id_or_scope, message) when is_map(message) do
    with {:ok, scope} <- scope(adapter_id_or_scope),
         {:ok, normalized} <- normalize(scope, message),
         :ok <- require_message_id(normalized),
         {:ok, execution} <- correlate(normalized),
         {:ok, outcome} <- persist(normalized, execution) do
      handle_persistence_outcome(outcome, normalized, execution)
    end
  end

  def ingest_inbound_message(_adapter_id_or_scope, _message), do: {:error, :invalid_message}

  defp require_message_id(%{message_id: id}) when is_binary(id) and id != "", do: :ok
  defp require_message_id(_normalized), do: {:error, :no_message_id}

  defp handle_persistence_outcome({:inserted, _event}, normalized, execution) do
    with :ok <- emit_inbound_message(normalized, execution),
         :ok <- route_reply(normalized, execution) do
      maybe_reschedule_ooo(normalized, execution)
    end
  end

  defp handle_persistence_outcome(:duplicate, normalized, execution) do
    emit_duplicate(normalized, execution)
    :ok
  end

  defp scope(adapter_id) when is_binary(adapter_id) do
    case Repo.get(ChannelAdapter, adapter_id) do
      %ChannelAdapter{} = adapter ->
        {:ok,
         %{
           adapter_id: adapter.id,
           tenant_key: adapter.tenant_key,
           channel: adapter.channel,
           provider: adapter.provider
         }}

      nil ->
        {:error, :adapter_not_found}
    end
  end

  defp scope(%{} = scope) do
    {:ok,
     %{
       adapter_id: Map.get(scope, :adapter_id, Map.get(scope, "adapter_id")),
       tenant_key: Map.get(scope, :tenant_key, Map.get(scope, "tenant_key")),
       channel: Map.get(scope, :channel, Map.get(scope, "channel", "email")),
       provider: Map.get(scope, :provider, Map.get(scope, "provider", "host"))
     }}
  end

  defp normalize(scope, message) do
    message = atomize(message)

    with :ok <- reject_unknown_keys(message),
         :ok <- require_keys(message),
         :ok <- validate_received_at(message.received_at) do
      {:ok,
       Map.merge(scope, %{
         message_id: normalize_message_id(Map.get(message, :message_id)),
         in_reply_to: normalize_message_id(Map.get(message, :in_reply_to)),
         references_list: normalize_references(Map.get(message, :references, [])),
         from: message.from,
         to: message.to,
         subject: Map.get(message, :subject),
         body_text: Map.get(message, :body_text),
         body_html: Map.get(message, :body_html),
         headers: Map.get(message, :headers, %{}),
         provider_message_id: provider_message_id(message),
         event_type: event_type(Map.get(message, :intent)),
         intent: Map.get(message, :intent),
         intent_data: Map.get(message, :intent_data, %{}),
         occurred_at: message.received_at
       })}
    end
  end

  defp reject_unknown_keys(message) do
    case Map.keys(message) -- @allowed_keys do
      [] -> :ok
      keys -> {:error, {:unknown_keys, keys}}
    end
  end

  defp require_keys(message) do
    case Enum.reject(@required_keys, &present?(Map.get(message, &1))) do
      [] -> :ok
      keys -> {:error, {:missing_keys, keys}}
    end
  end

  defp validate_received_at(%DateTime{}), do: :ok
  defp validate_received_at(_value), do: {:error, :invalid_received_at}

  defp correlate(normalized) do
    execution =
      execution_by_out_message_id(normalized) ||
        Correlation.by_provider_message_id(normalized)

    if is_nil(execution), do: emit_unmatched(normalized)

    {:ok, execution}
  end

  defp execution_by_out_message_id(%{in_reply_to: nil}), do: nil

  defp execution_by_out_message_id(normalized) do
    ids = message_id_candidates(normalized.in_reply_to)
    Correlation.by_out_message_id(normalized, ids)
  end

  defp persist(normalized, execution) do
    changeset =
      MessageEvent.changeset(%MessageEvent{}, %{
        step_execution_id: execution && execution.id,
        adapter_id: adapter_id_for(normalized, execution),
        tenant_key: (execution && execution.tenant_key) || normalized.tenant_key,
        channel: normalized.channel,
        provider: normalized.provider,
        provider_message_id: normalized.message_id || normalized.provider_message_id,
        provider_event_id: normalized.message_id,
        event_type: normalized.event_type,
        event_data: Redact.scrub(event_data(normalized)),
        in_reply_to: normalized.in_reply_to,
        references_list: normalized.references_list,
        occurred_at: normalized.occurred_at || Clock.now()
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment,
              "(provider, provider_event_id) WHERE provider_event_id IS NOT NULL"}
         ) do
      {:ok, %MessageEvent{id: nil}} -> {:ok, :duplicate}
      {:ok, %MessageEvent{} = event} -> {:ok, {:inserted, event}}
      {:error, _changeset} = error -> error
    end
  end

  defp route_reply(%{event_type: "replied"} = normalized, execution) do
    OnReply.handle_reply(normalized, execution)
  end

  defp route_reply(_normalized, _execution), do: :ok

  defp maybe_reschedule_ooo(%{intent: intent} = normalized, execution)
       when intent in [:ooo, "ooo"] and not is_nil(execution) do
    return_at = return_at(normalized.intent_data)

    if return_at do
      reschedule_ooo(normalized, execution, return_at)
    else
      :ok
    end
  end

  defp maybe_reschedule_ooo(_normalized, _execution), do: :ok

  defp reschedule_ooo(normalized, execution, return_at) do
    execution = Repo.repo!().preload(execution, :enrollment)
    scheduled_for = DateTime.new!(return_at, ~T[09:00:00], "Etc/UTC")

    query =
      StepExecution
      |> where([step_execution], step_execution.enrollment_id == ^execution.enrollment_id)
      |> where([step_execution], step_execution.state == "scheduled")

    event_changeset =
      Event.changeset(%Event{}, %{
        enrollment_id: execution.enrollment_id,
        tenant_key: execution.enrollment.tenant_key,
        subscriber_type: execution.enrollment.subscriber_type,
        subscriber_id: execution.enrollment.subscriber_id,
        event_type: "enrollment_event",
        event_key: "ooo_rescheduled",
        event_data: %{"return_at" => Date.to_iso8601(return_at)},
        occurred_at: Clock.now()
      })

    Multi.new()
    |> Multi.update_all(:rescheduled, query,
      set: [scheduled_for: scheduled_for, updated_at: Clock.now()]
    )
    |> Multi.insert(:event, event_changeset)
    |> Repo.transaction()
    |> case do
      {:ok, _result} ->
        :telemetry.execute([:dripdrop, :ingest, :ooo_rescheduled], %{count: 1}, %{
          enrollment_id: execution.enrollment_id,
          return_at: return_at,
          scheduled_for: scheduled_for,
          tenant_key: normalized.tenant_key
        })

        :ok

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp event_data(normalized) do
    %{
      "from" => normalized.from,
      "to" => normalized.to,
      "subject" => normalized.subject,
      "body_text" => normalized.body_text,
      "body_html" => normalized.body_html,
      "headers" => normalized.headers,
      "intent" => normalized.intent,
      "intent_data" => encode_dates(normalized.intent_data)
    }
  end

  defp encode_dates(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_dates(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp encode_dates(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, encode_dates(value)} end)
  end

  defp encode_dates(list) when is_list(list), do: Enum.map(list, &encode_dates/1)
  defp encode_dates(value), do: value

  defp event_type(nil), do: "replied"
  defp event_type(:reply), do: "replied"
  defp event_type("reply"), do: "replied"
  defp event_type(:ooo), do: "replied"
  defp event_type("ooo"), do: "replied"
  defp event_type(:auto_reply), do: "replied"
  defp event_type("auto_reply"), do: "replied"

  defp provider_message_id(%{headers: headers}) do
    header(headers, "x-provider-message-id") || header(headers, "X-Provider-Message-ID")
  end

  defp provider_message_id(_message), do: nil

  defp header(headers, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == String.downcase(name), do: value
    end)
    |> normalize_message_id()
  end

  defp header(_headers, _name), do: nil

  defp normalize_references(references) when is_binary(references) do
    references
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&normalize_message_id/1)
  end

  defp normalize_references(references) when is_list(references),
    do: Enum.map(references, &normalize_message_id/1)

  defp normalize_references(_references), do: []

  defp normalize_message_id(nil), do: nil

  defp normalize_message_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  defp message_id_candidates(message_id) do
    normalized = normalize_message_id(message_id)
    [normalized, "<#{normalized}>"]
  end

  defp return_at(intent_data) when is_map(intent_data) do
    Map.get(intent_data, :return_at) || Map.get(intent_data, "return_at")
  end

  defp return_at(_intent_data), do: nil

  defp present?(value), do: not (is_nil(value) or value == "")

  defp atomize(map) do
    Map.new(map, fn {key, value} -> {DripDrop.Helpers.atom_or_string(key), value} end)
  end

  defp adapter_id_for(_normalized, %StepExecution{metadata: %{"adapter_id" => adapter_id}})
       when is_binary(adapter_id),
       do: adapter_id

  defp adapter_id_for(%{adapter_id: adapter_id}, _execution) when is_binary(adapter_id),
    do: adapter_id

  defp adapter_id_for(_normalized, _execution), do: nil

  defp emit_unmatched(normalized) do
    :telemetry.execute([:dripdrop, :ingest, :unmatched_event], %{count: 1}, %{
      provider: normalized.provider,
      provider_message_id: normalized.provider_message_id,
      provider_event_id: normalized.message_id
    })
  end

  defp emit_duplicate(normalized, execution) do
    :telemetry.execute([:dripdrop, :ingest, :duplicate_event], %{count: 1}, %{
      provider: normalized.provider,
      provider_event_id: normalized.message_id,
      step_execution_id: execution && execution.id,
      tenant_key: (execution && execution.tenant_key) || normalized.tenant_key
    })
  end

  defp emit_inbound_message(normalized, execution) do
    :telemetry.execute([:dripdrop, :ingest, :inbound_message], %{count: 1}, %{
      provider: normalized.provider,
      provider_message_id: normalized.provider_message_id,
      provider_event_id: normalized.message_id,
      step_execution_id: execution && execution.id,
      tenant_key: (execution && execution.tenant_key) || normalized.tenant_key,
      intent: normalized.intent
    })

    :ok
  end
end
