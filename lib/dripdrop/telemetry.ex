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

    * `:tenant_key` - tenant scope when the event is tied to persisted data.
    * `:step_execution_id` - dispatch or policy row being processed.
    * `:channel` and `:provider` - delivery surface that emitted the event.
    * `:adapter_id` - channel adapter id when adapter-specific.
    * `:defer_until` - UTC `DateTime` for deferral decisions.
    * `:provider_message_id` and `:provider_event_id` - inbound provider
      identifiers for webhook ingest.
  """

  @events [
    [:dripdrop, :dispatch, :concurrency_limited],
    [:dripdrop, :dispatch, :phase, :start],
    [:dripdrop, :dispatch, :phase, :stop],
    [:dripdrop, :policy, :suppressed],
    [:dripdrop, :policy, :quiet_hours],
    [:dripdrop, :policy, :rate_limited],
    [:dripdrop, :policy, :bounce_threshold],
    [:dripdrop, :policy, :complaint_threshold],
    [:dripdrop, :policy, :daily_cap],
    [:dripdrop, :condition, :fail_closed],
    [:dripdrop, :condition, :coercion_error],
    [:dripdrop, :hook, :exception],
    [:dripdrop, :ingest, :duplicate],
    [:dripdrop, :ingest, :signature_failure],
    [:dripdrop, :ingest, :unmatched_event],
    [:dripdrop, :template, :render],
    [:dripdrop, :template, :missing_variable],
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
