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


### Requirement: Per-(Adapter, Sequence-Version) Sub-Cap Provides Blast-Radius Protection

The system SHALL persist `dripdrop.adapter_sequence_budgets` rows with `adapter_id`, `sequence_version_id`, `weight` (integer, default 1), `max_share_pct` (integer in `[1, 100]`, default 100), `daily_volume_target` (integer, nullable), `inserted_at`, `updated_at`. For outbound-mode enrollments, before sending the system SHALL compute the sequence's allocated share of the adapter's effective daily cap as `floor(effective_cap_today(adapter) * max_share_pct / 100)`, then count today's sends from this adapter for this sequence-version, and defer when the share is exhausted. The constraint applies in addition to (and is bounded by) the adapter-level daily cap.

#### Scenario: Sub-cap prevents one sequence from burning all headroom
- **WHEN** adapter `gmail_a` has `effective_cap_today = 30`, sequence A has `max_share_pct = 50`, sequence B has `max_share_pct = 50`, both share `gmail_a`, and sequence A has already sent 15 today
- **THEN** sequence A's next send defers (it has reached its 50% sub-cap of 15), but sequence B can still send up to 15 of its own.

#### Scenario: Default 100% sub-cap behaves as no-op
- **WHEN** an adapter-sequence budget defaults to `max_share_pct = 100` and `weight = 1`
- **THEN** the sub-cap gate evaluates to "no constraint beyond the adapter cap" and dispatch proceeds without sub-cap-driven deferral.

#### Scenario: Sub-cap deferral emits telemetry
- **WHEN** a sub-cap defers an execution
- **THEN** `[:dripdrop, :policy, :sub_cap]` telemetry fires with `adapter_id`, `sequence_version_id`, `share_count`, `share_cap`, `defer_until`.

### Requirement: Daily Cap Adds Adapter-ID Keying As A Parallel Constraint For Outbound

For outbound-mode enrollments, the system SHALL enforce a daily cap keyed on `adapter_id` in addition to the foundation's `sender_mailbox`-keyed daily cap. The query path SHALL count `message_events` where `event_type = 'sent' AND event_data->>'adapter_id' = $adapter_id` over the day boundary in the configured timezone. The stricter of (sender-mailbox cap, adapter-id cap, ramp-effective cap, sub-cap share) SHALL win on each dispatch attempt. Lifecycle dispatch SHALL continue to use only the `sender_mailbox`-keyed cap (foundation behavior preserved).

#### Scenario: Adapter-id cap catches ESP-API account-level exhaustion
- **WHEN** an outbound enrollment's pinned adapter is a Mailgun account with `daily_cap = 1000`, the account has sent 1000 emails today across many `from` addresses, and a new send attempts
- **THEN** the adapter-id cap is exhausted (regardless of `sender_mailbox` cap state), the execution defers, and `[:dripdrop, :policy, :daily_cap]` telemetry fires with `keying: :adapter_id`.

#### Scenario: OAuth-mailbox cap matches across keying paths
- **WHEN** an outbound enrollment's pinned adapter is a Gmail OAuth mailbox where adapter ≈ mailbox 1:1
- **THEN** the `sender_mailbox` cap and `adapter_id` cap converge on the same count; either path defers correctly when 30 sends have occurred against `daily_cap = 30`.

### Requirement: Min-Gap-Between-Sends Enforces Cross-Sequence Spacing

The system SHALL implement `DripDrop.Policy.MinGap.check/2` that runs in the dispatch path between concurrency check and rate-limit check. The check SHALL refuse to dispatch when `now() - adapter.last_send_at < adapter.min_gap_seconds`, deferring with `scheduled_for = adapter.last_send_at + min_gap_seconds`. The `last_send_at` value is updated atomically with the `state → "sent"` transition (already specified in the `channel-adapters` capability). The constraint applies across all sequences using the adapter, not per-sequence.

#### Scenario: Min-gap enforced across two sequences
- **WHEN** adapter `gmail_a` has `min_gap_seconds = 90`, sequence A sent at 10:00:00, sequence B attempts to send at 10:00:30
- **THEN** sequence B defers to 10:01:30, emits `[:dripdrop, :policy, :min_gap]`, and does NOT call the channel adapter.

#### Scenario: Adapters without min_gap configured skip the gate
- **WHEN** an adapter has `min_gap_seconds IS NULL`
- **THEN** the min-gap gate short-circuits and dispatch proceeds through the next gate.

### Requirement: Adapter Health State Engages The Resting Cooldown In The Dispatch Path

For outbound-mode enrollments, before any send the system SHALL check the pinned adapter's `health_state` and `resting_until`. When `health_state == "resting"` and `resting_until > now()`, dispatch SHALL defer the execution with `scheduled_for = resting_until` (or `pool.on_pin_unavailable` policy when `resting_until` is far enough in the future to warrant pause/reassign — see `dispatch-execution` capability). The check SHALL run BEFORE all other outbound-only gates so a resting adapter doesn't waste cycles on subsequent gate evaluation.

#### Scenario: Resting adapter defers to recovery time
- **WHEN** an outbound enrollment's pinned adapter has `health_state = "resting", resting_until = now() + 4 hours`
- **THEN** dispatch defers with `scheduled_for = resting_until`, emits `[:dripdrop, :policy, :adapter_resting]` with `health_state, resting_until, adapter_id`, and skips the remaining outbound gates.

#### Scenario: Probing adapter passes the health gate but uses probe cap
- **WHEN** an outbound enrollment's pinned adapter has `health_state = "probing"`
- **THEN** the health gate allows dispatch (probing is an active sending state), but the ramp cap gate uses the configured probe-phase budget instead of the linear ramp formula (per the `channel-adapters` capability).
