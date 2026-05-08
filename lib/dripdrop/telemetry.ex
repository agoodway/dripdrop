defmodule DripDrop.Telemetry do
  @moduledoc """
  Telemetry event catalogue for DripDrop.

  Host applications attach handlers to these events through `:telemetry`.
  DripDrop does not prescribe a logging or APM backend.

  ## Recommended Phoenix attachment

      :telemetry.attach_many(
        "dripdrop-logger",
        DripDrop.Telemetry.events(),
        &MyAppWeb.Telemetry.handle_event/4,
        nil
      )

  Each event includes a small measurements map and a provider-specific metadata
  map. Measurements are intentionally stable: counters use `%{count: integer}`
  and threshold checks use `%{rate: float}`.

  Common metadata keys:

    * `:tenant_key :: binary() | nil` - tenant scope when the event is tied to persisted data.
    * `:step_execution_id :: Ecto.UUID.t() | nil` - dispatch or policy row being processed.
    * `:channel :: binary()` and `:provider :: binary()` - delivery surface that emitted the event.
    * `:adapter_id :: Ecto.UUID.t()` - channel adapter id when adapter-specific.
    * `:defer_until :: DateTime.t()` - UTC time for deferral decisions.
    * `:reason :: atom() | binary()` - policy, health, or template reason.
    * `:provider_message_id :: binary() | nil` and `:provider_event_id :: binary() | nil` - inbound provider identifiers for webhook ingest.

  Cold-outbound events:

    * `[:dripdrop, :dispatch, :adapter_pinned]` - enrollment pinned to a pool adapter.
      Metadata: `:enrollment_id`, `:sequence_version_id`, `:adapter_id`, `:tenant_key`.
    * `[:dripdrop, :dispatch, :pool_exhausted]` - no eligible pool member.
      Metadata: `:pool_id`, `:sequence_version_id`, `:evicted_adapter_ids`, `:tenant_key`.
    * `[:dripdrop, :policy, :adapter_resting]` - outbound adapter is resting.
      Metadata: `:adapter_id`, `:step_execution_id`, `:tenant_key`, `:defer_until`.
    * `[:dripdrop, :policy, :ramp_cap]` - adapter effective daily cap hit.
      Metadata: `:adapter_id`, `:step_execution_id`, `:tenant_key`, `:sent_count`, `:cap`.
    * `[:dripdrop, :policy, :sub_cap]` - sequence share cap hit.
      Metadata: `:adapter_id`, `:sequence_version_id`, `:step_execution_id`, `:tenant_key`, `:sent_count`, `:cap`, `:max_share_pct`.
    * `[:dripdrop, :policy, :min_gap]` - adapter minimum-send gap hit.
      Metadata: `:adapter_id`, `:step_execution_id`, `:tenant_key`, `:defer_until`, `:min_gap_seconds`.
    * `[:dripdrop, :health, :state_changed]` - adapter health transition.
      Metadata: `:adapter_id`, `:tenant_key`, `:from`, `:to`, `:reason`, `:source`.
    * `[:dripdrop, :health, :external_signal]` - host health signal accepted.
      Metadata: `:adapter_id`, `:tenant_key`, `:health_state`, `:health_score`, `:source`.
    * `[:dripdrop, :ingest, :inbound_message]` - host inbound message persisted.
      Metadata: `:provider`, `:provider_message_id`, `:provider_event_id`, `:step_execution_id`, `:tenant_key`, `:intent`.
    * `[:dripdrop, :ingest, :ooo_rescheduled]` - OOO intent moved scheduled executions.
      Metadata: `:enrollment_id`, `:return_at`, `:scheduled_for`, `:tenant_key`.
    * `[:dripdrop, :enrollment, :paused_pin_unavailable]` - pinned adapter became terminally unavailable.
      Metadata: `:enrollment_id`, `:adapter_id`, `:tenant_key`.
    * `[:dripdrop, :enrollment, :sender_reassigned]` - adapter pin changed.
      Metadata: `:enrollment_id`, `:old_adapter_id`, `:new_adapter_id`, `:reason`, `:tenant_key`.
    * `[:dripdrop, :template, :spintax_error]` - malformed spintax fell back to original text.
      Metadata: `:reason`, `:text`, `:step_execution_id`, `:attempt_window`.
    * `[:dripdrop, :template, :spintax_warning]` - recoverable spintax issue.
      Metadata: `:reason`, `:token`, `:step_execution_id`, `:attempt_window`.
  """

  @events [
    [:dripdrop, :dispatch, :concurrency_limited],
    [:dripdrop, :dispatch, :adapter_pinned],
    [:dripdrop, :dispatch, :pool_exhausted],
    [:dripdrop, :dispatch, :phase, :start],
    [:dripdrop, :dispatch, :phase, :stop],
    [:dripdrop, :enrollment, :paused_pin_unavailable],
    [:dripdrop, :enrollment, :sender_reassigned],
    [:dripdrop, :health, :external_signal],
    [:dripdrop, :health, :state_changed],
    [:dripdrop, :policy, :suppressed],
    [:dripdrop, :policy, :quiet_hours],
    [:dripdrop, :policy, :rate_limited],
    [:dripdrop, :policy, :bounce_threshold],
    [:dripdrop, :policy, :complaint_threshold],
    [:dripdrop, :policy, :daily_cap],
    [:dripdrop, :policy, :adapter_resting],
    [:dripdrop, :policy, :ramp_cap],
    [:dripdrop, :policy, :sub_cap],
    [:dripdrop, :policy, :min_gap],
    [:dripdrop, :condition, :fail_closed],
    [:dripdrop, :condition, :coercion_error],
    [:dripdrop, :hook, :exception],
    [:dripdrop, :ingest, :duplicate],
    [:dripdrop, :ingest, :inbound_message],
    [:dripdrop, :ingest, :ooo_rescheduled],
    [:dripdrop, :ingest, :signature_failure],
    [:dripdrop, :ingest, :unmatched_event],
    [:dripdrop, :template, :render],
    [:dripdrop, :template, :missing_variable],
    [:dripdrop, :template, :spintax_error],
    [:dripdrop, :template, :spintax_warning],
    [:dripdrop, :short_link, :fallback],
    [:dripdrop, :channel, :token_unavailable],
    [:dripdrop, :webhook, :body_too_large],
    [:dripdrop, :webhook, :replay_window],
    [:dripdrop, :hook, :url_blocked]
  ]

  @doc """
  Returns all telemetry event names emitted by DripDrop.

  ## Example

      :telemetry.attach_many(
        "dripdrop-observer",
        DripDrop.Telemetry.events(),
        &MyApp.Telemetry.handle_event/4,
        nil
      )
  """
  @spec events() :: [[atom()]]
  def events, do: @events
end
