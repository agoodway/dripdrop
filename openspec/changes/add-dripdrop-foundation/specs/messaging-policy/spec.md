## ADDED Requirements

### Requirement: Suppression List Is Checked Before Every Send

The system SHALL persist `dripdrop.suppressions` keyed uniquely on `(channel, recipient_normalized)` with `reason` (`unsubscribe | bounce | complaint | manual | provider_block`), `source`, and `metadata`. Recipients SHALL be normalized per channel: emails lower-cased and trimmed; phone numbers in E.164 (`+15551234567`); webhook URLs by exact match; Slack/Telegram by channel-id/chat-id. Dispatch SHALL query the suppression list as a precondition and SHALL skip (transition `claiming → skipped`) when a match exists.

#### Scenario: Suppressed email skipped
- **WHEN** an `email` execution targets `Ada@Example.com` and a suppression exists for `("email", "ada@example.com")` with `reason: "complaint"`
- **THEN** dispatch transitions the row to `skipped`, writes a `message_events` entry with `event_type: "suppressed"`, and proceeds to schedule the next step.

#### Scenario: Phone normalization
- **WHEN** an SMS execution targets `(555) 123-4567` and a suppression exists for `("sms", "+15551234567")`
- **THEN** the normalized recipient matches and the send is skipped.

### Requirement: Bulk Email Sends Apply RFC 8058 List-Unsubscribe Headers

When the channel is `email` and the step's `config["operating_mode"]` is `bulk` (the default for sequenced lifecycle/marketing email), the system SHALL append two headers: `List-Unsubscribe: <https://...>, <mailto:unsubscribe@...>` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`. The unsubscribe URL SHALL be tenant- and recipient-specific, signed, and resolvable via `DripDrop.Web.unsubscribe_handler/2`. DKIM signing of the outgoing email SHALL be required (verified via the configured Swoosh adapter or domain configuration); when DKIM is not configured the change SHALL fail at boot via `DripDrop.startup_check/0`.

#### Scenario: Bulk email gets headers
- **WHEN** an email step has `operating_mode: "bulk"` and the host has configured `unsubscribe_url_builder`
- **THEN** the outgoing `%Swoosh.Email{}` carries `List-Unsubscribe` and `List-Unsubscribe-Post` headers exactly as specified by RFC 8058.

#### Scenario: Transactional email omits headers when explicit
- **WHEN** the step is marked `operating_mode: "transactional"`
- **THEN** the unsubscribe headers are NOT added; `messaging-policy` still consults the suppression list (manual/provider_block reasons), but `unsubscribe`-reason suppressions DO NOT block transactional sends.

### Requirement: Quiet Hours Are Enforced Against Recipient Local Time

When a step has `config["quiet_hours"]` set (or the global config is set), the system SHALL compute the recipient's local time using `enrollment.data["timezone"]` (preferred), then a per-channel fallback (e.g., area-code lookup for SMS, or `tenant.default_timezone`), and SHALL defer execution outside the configured window. SMS SHALL default to TCPA-compliant 8 AM–9 PM recipient-local. Deferral SHALL update `step_executions.scheduled_for` to the next allowed minute and re-enqueue.

#### Scenario: SMS deferred outside quiet hours
- **WHEN** an SMS execution claims at 22:30 local time and quiet hours are 21:00–08:00
- **THEN** `scheduled_for` is set to 08:00 local on the next day, the execution transitions back to `scheduled`, and PgFlow re-enqueues for that time.

#### Scenario: Quiet hours override per step
- **WHEN** a step's `config["quiet_hours"]` is `false` (transactional override)
- **THEN** the policy gate is bypassed for that step.

### Requirement: Rate Limits Are Enforced At Multiple Scopes

The system SHALL enforce rate limits at four scopes simultaneously: per-`channel_adapter_id`, per-`provider`, per-sending-domain (extracted from the `from`/`reply-to` for email), and per-recipient. Limits SHALL be configurable via `channel_adapters.config["rate_limits"]` and step-level overrides. Implementation SHALL use a token-bucket against either Postgres advisory locks or a Redis backend (configurable). Limit hits SHALL reschedule (no error), not fail.

#### Scenario: Adapter limit hit reschedules
- **WHEN** the configured rate limit for an adapter is 60 per minute and a 61st execution claims within the same minute
- **THEN** the execution defers `scheduled_for` to the next bucket boundary and emits `[:dripdrop, :policy, :rate_limited]` telemetry; it does NOT fail or skip.

#### Scenario: Per-recipient limit
- **WHEN** an enrollment causes a third dispatch to the same `recipient` within 24 hours and the global per-recipient limit is `2/24h`
- **THEN** the third send is deferred until the rolling window allows.

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

### Requirement: Cold-Outbound Operating Mode Adds Conservative Defaults

When `step.config["operating_mode"] == "cold"`, the system SHALL apply: plain-text body required (HTML SHALL be rejected at validation), per-mailbox daily cap defaulting to 50/day for fresh adapters and configurable up to 500/day for warm adapters, sender-domain isolation check (the configured `from` SHALL not match the host's primary marketing domain unless `cold.allow_primary_domain: true`), and an explicit verified-recipient flag in `enrollment.data["recipient_verified_at"]` (otherwise the send is skipped with `reason: "unverified_recipient"`).

#### Scenario: Cold step rejects HTML body
- **WHEN** a step is created with `operating_mode: "cold"` and `body_format: "mjml"` or HTML
- **THEN** authoring validation rejects the step with `{:error, [:cold_requires_plain_text]}`.

#### Scenario: Cold daily cap deferral
- **WHEN** a cold adapter has already sent 50 messages in the current day and a 51st execution claims
- **THEN** the execution defers to the next day boundary in the adapter's configured timezone and emits `[:dripdrop, :policy, :cold_cap]`.

### Requirement: Audit Snapshot Is Persisted For Each Execution With Redaction

Each `step_executions` row SHALL record `payload` (the rendered output sent to the adapter), `response` (the adapter's normalized response), and `provider_message_id`. Secrets matching the configured redaction patterns (default: `~r/(?i)(api[_-]?key|secret|token|password|authorization)/`) SHALL be replaced with `"[REDACTED]"` in stored payload/response. Adapter `credentials` SHALL never appear in the audit row.

#### Scenario: Auth header redacted in webhook payload snapshot
- **WHEN** a webhook step's request includes `Authorization: Bearer abc123`
- **THEN** the persisted `payload.headers["Authorization"]` is `"[REDACTED]"`.
