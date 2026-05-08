# messaging-policy

## Purpose

Messaging policy defines safety and compliance gates applied before delivery, including suppressions, quiet hours, rate limits, thresholds, and sending rules.

## Requirements

### Requirement: Suppression List Is Checked Before Every Send

The system SHALL persist `dripdrop.suppressions` keyed uniquely on `(channel, recipient_normalized)` with `reason` (`unsubscribe | bounce | complaint | manual | provider_block`), `source`, and `metadata`. Recipients SHALL be normalized per channel: emails lower-cased and trimmed; phone numbers in E.164 (`+15551234567`); webhook URLs by exact match; Slack/Telegram by channel-id/chat-id. Dispatch SHALL query the suppression list as a precondition and SHALL skip (transition `claiming → skipped`) when a match exists.

#### Scenario: Suppressed email skipped
- **WHEN** an `email` execution targets `Ada@Example.com` and a suppression exists for `("email", "ada@example.com")` with `reason: "complaint"`
- **THEN** dispatch transitions the row to `skipped`, writes a `message_events` entry with `event_type: "suppressed"`, and proceeds to schedule the next step.

#### Scenario: Phone normalization
- **WHEN** an SMS execution targets `(555) 123-4567` and a suppression exists for `("sms", "+15551234567")`
- **THEN** the normalized recipient matches and the send is skipped.

### Requirement: Email Steps May Opt Into RFC 8058 List-Unsubscribe Headers

When the channel is `email` and the step sets `config["unsubscribe_headers"] == true` or `config["unsubscribe"] == true`, the system SHALL append two headers: `List-Unsubscribe: <https://...>, <mailto:unsubscribe@...>` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`. The unsubscribe URL SHALL be tenant- and recipient-specific, signed, and resolvable via `DripDrop.Web.unsubscribe_handler/2`. When any configured step opts into unsubscribe headers, `DripDrop.startup_check/0` SHALL fail unless `unsubscribe_url_builder` is configured.

#### Scenario: Opted-in email gets headers
- **WHEN** an email step has `unsubscribe_headers: true` and the host has configured `unsubscribe_url_builder`
- **THEN** the outgoing `%Swoosh.Email{}` carries `List-Unsubscribe` and `List-Unsubscribe-Post` headers exactly as specified by RFC 8058.

#### Scenario: Email without opt-in omits headers
- **WHEN** an email step does not opt into unsubscribe headers
- **THEN** the unsubscribe headers are NOT added.

### Requirement: Quiet Hours Are Enforced Against Recipient Local Time

When a step has `config["quiet_hours"]` set (or the global config is set), the system SHALL compute the recipient's local time using `enrollment.data["timezone"]` (preferred), then a per-channel fallback (e.g., area-code lookup for SMS, or `tenant.default_timezone`), and SHALL defer execution outside the configured window. SMS SHALL default to TCPA-compliant 8 AM–9 PM recipient-local. Deferral SHALL update `step_executions.scheduled_for` to the next allowed minute and re-enqueue.

#### Scenario: SMS deferred outside quiet hours
- **WHEN** an SMS execution claims at 22:30 local time and quiet hours are 21:00–08:00
- **THEN** `scheduled_for` is set to 08:00 local on the next day, the execution transitions back to `scheduled`, and PgFlow re-enqueues for that time.

#### Scenario: Quiet hours disabled per step
- **WHEN** a step's `config["quiet_hours"]` is `false`
- **THEN** the policy gate is bypassed for that step.

### Requirement: Rate Limits Are Enforced At Multiple Scopes

The system SHALL enforce rate limits at five scopes simultaneously: per-`channel_adapter_id`, per-`provider`, per-sending-domain (extracted from the `from`/`reply-to` for email), per-recipient-domain (extracted from the `to`/`recipient` address for email), and per-recipient. Limits SHALL be configurable via `channel_adapters.config["rate_limits"]` and step-level overrides. Implementation SHALL use a token-bucket against either Postgres advisory locks or a Redis backend (configurable). Limit hits SHALL reschedule (no error), not fail.

#### Scenario: Adapter limit hit reschedules
- **WHEN** the configured rate limit for an adapter is 60 per minute and a 61st execution claims within the same minute
- **THEN** the execution defers `scheduled_for` to the next bucket boundary and emits `[:dripdrop, :policy, :rate_limited]` telemetry; it does NOT fail or skip.

#### Scenario: Per-recipient limit
- **WHEN** an enrollment causes a third dispatch to the same `recipient` within 24 hours and the global per-recipient limit is `2/24h`
- **THEN** the third send is deferred until the rolling window allows.

#### Scenario: Per-recipient-domain limit protects against intra-domain spikes
- **WHEN** the configured `recipient_domain` rate limit is `10/minute` and an eleventh execution within the same minute targets a recipient at `gmail.com` while ten prior sends to other `gmail.com` recipients are still in the bucket
- **THEN** the execution defers to the next bucket boundary, emits `[:dripdrop, :policy, :rate_limited]` with `scope: :recipient_domain` and `key: "email:gmail.com"`, and is NOT counted against the per-recipient or adapter buckets twice.

### Requirement: Bounce And Complaint Thresholds Trigger Auto-Suppression

The system SHALL compute, per-`channel_adapter_id` over a rolling 30-day window: complaint rate (complaints / sent), hard-bounce rate (hard bounces / sent), and total bounce rate. The system SHALL emit telemetry and SHALL automatically suppress the offending recipient when:

- Hard bounce on the recipient → `suppressions(reason: "bounce")` immediately.
- Complaint on the recipient → `suppressions(reason: "complaint")` immediately.
- Adapter complaint rate exceeds 0.3 % over 30 days → emit `[:dripdrop, :policy, :complaint_threshold]` and pause new sends from that adapter pending operator review.
- Adapter bounce rate exceeds 2 % over 30 days → emit `[:dripdrop, :policy, :bounce_threshold]` and pause new sends from that adapter pending operator review.

#### Scenario: Hard bounce auto-suppresses recipient
- **WHEN** an inbound provider event reports a hard bounce for `ada@example.com`
- **THEN** a `suppressions` row with `(channel: "email", recipient: "ada@example.com", reason: "bounce")` is upserted.

#### Scenario: Adapter exceeds complaint rate
- **WHEN** a Mailgun adapter has 4 complaints out of 1000 sent in 30 days (0.4 %)
- **THEN** the adapter's rate-limit gate engages a synthetic "paused" state preventing new claims, and operators see `complaint_threshold: 0.4` in telemetry.

#### Scenario: Paused adapter blocks new dispatches until resume
- **WHEN** an adapter has `config["paused_until"]` set to a future timestamp because a prior threshold breach engaged the synthetic paused state
- **THEN** dispatch SHALL detect the paused state during adapter resolution, defer the execution by transitioning back to `scheduled` with `scheduled_for = paused_until`, emit `[:dripdrop, :policy, :adapter_paused]` telemetry with `adapter_id`, `paused_reason`, and `paused_until`, and SHALL NOT call the channel provider's `deliver/3`.

#### Scenario: Paused adapter resumes automatically when window expires
- **WHEN** an adapter's `config["paused_until"]` has passed in wall-clock time and a new execution claims
- **THEN** dispatch proceeds without intervention, the existing `paused_until` value is left intact (operators see audit history), and the adapter participates in selection as usual unless a new threshold breach re-engages the pause.

### Requirement: Sending Rules Add Optional Per-Sender Controls

When a step or adapter configures explicit sending rules, the system SHALL apply those rules without classifying the message into an operating mode. Supported rules include per-sender daily caps and `require_verified_recipient`. Daily caps are keyed by sender mailbox and defer to the next day boundary in the configured timezone. When `require_verified_recipient` is true and `enrollment.data["recipient_verified_at"]` is missing, dispatch SHALL skip with `reason: "unverified_recipient"`.

#### Scenario: Verified-recipient requirement skips missing verification
- **WHEN** a step has `require_verified_recipient: true` and the enrollment lacks `recipient_verified_at`
- **THEN** dispatch skips the execution with `reason: "unverified_recipient"`.

#### Scenario: Daily cap deferral
- **WHEN** a sender mailbox has already reached its configured daily cap and the next execution claims
- **THEN** the execution defers to the next day boundary in the configured timezone and emits `[:dripdrop, :policy, :daily_cap]`.

### Requirement: Audit Snapshot Is Persisted For Each Execution With Redaction

Each `step_executions` row SHALL record `payload` (the rendered output sent to the adapter), `response` (the adapter's normalized response), and `provider_message_id`. Secrets matching the configured redaction patterns (default: `~r/(?i)(api[_-]?key|secret|token|password|authorization)/`) SHALL be replaced with `"[REDACTED]"` in stored payload/response. Adapter `credentials` SHALL never appear in the audit row.

#### Scenario: Auth header redacted in webhook payload snapshot
- **WHEN** a webhook step's request includes `Authorization: Bearer abc123`
- **THEN** the persisted `payload.headers["Authorization"]` is `"[REDACTED]"`.
