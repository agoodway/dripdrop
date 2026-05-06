## ADDED Requirements

### Requirement: Webhook Ingest Plug Is Mounted By The Host App

The library SHALL expose `DripDrop.Web.WebhookPlug` and a router macro `DripDrop.Web.Router.dripdrop_webhooks(path)` that mounts a single base path under which all adapter-declared inbound webhook routes resolve as subpaths. The macro SHALL be safe to mount inside any Phoenix endpoint and SHALL NOT depend on Phoenix.

#### Scenario: Mount under /webhooks
- **WHEN** the host app calls `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")`
- **THEN** Mailgun events POST to `/webhooks/dripdrop/mailgun/:adapter_id`, Twilio events POST to `/webhooks/dripdrop/twilio/:adapter_id`, etc.

### Requirement: Provider Signatures Are Verified Before Persistence

For every supported provider that ships outbound webhook events (`mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`, `twilio`), the ingest path SHALL verify the request signature using the corresponding adapter's stored credentials before any database write. Verification failure SHALL return `401` and SHALL log a `[:dripdrop, :ingest, :signature_failure]` telemetry event with `provider`, `adapter_id`, and the request id (NEVER the body or headers). Unsupported providers SHALL return `404`.

Providers that do **not** push delivery events through webhooks (`gmail`, `ms365`, `smtp`, `pubsub`, `slack`, `telegram`) SHALL NOT register webhook routes. For those providers, `step_executions` transitions to `sent` on a successful API response, and downstream `delivered`/`bounced`/`complained` signals are not available — `messaging-policy` SHALL still apply suppressions on synchronous send-time errors (e.g., a 5xx Gmail response indicating a hard failure).

#### Scenario: Mailgun signature verification
- **WHEN** a Mailgun webhook hits `/webhooks/dripdrop/mailgun/<adapter_id>` with valid `timestamp`, `token`, and `signature` HMAC'd with the adapter's API key
- **THEN** the request is accepted and an event is enqueued for processing.

#### Scenario: Invalid signature
- **WHEN** the same Mailgun webhook is sent with a tampered signature
- **THEN** the response is `401`, no `message_events` row is written, and a `signature_failure` telemetry event fires.

### Requirement: Inbound Events Are Normalized Into `message_events`

Verified provider events SHALL be normalized into `dripdrop.message_events` rows with: `step_execution_id` (resolved by `provider_message_id` lookup, NULLABLE if no match), `channel`, `provider`, `provider_message_id`, `event_type` (`delivered | bounced | complained | opened | clicked | replied | unsubscribed | failed | rejected`), `event_data` JSONB (raw provider payload, with secrets redacted), and `occurred_at` (parsed from the provider event, falling back to `now()`).

#### Scenario: Delivered event
- **WHEN** Mailgun posts a `delivered` event with `message-id: <abc@example>` matching `step_executions.provider_message_id`
- **THEN** a `message_events` row is inserted with `event_type: "delivered"`, `step_execution_id` linked, and the raw payload stored under `event_data` with redaction applied.

#### Scenario: Unmatched provider id
- **WHEN** an event references a `provider_message_id` not present in any `step_executions` row
- **THEN** the event is still persisted with `step_execution_id IS NULL` so out-of-band acknowledgments are not dropped, and a `[:dripdrop, :ingest, :unmatched_event]` telemetry event fires.

### Requirement: Bounce, Complaint, And Unsubscribe Events Update Suppressions Atomically

When an event is `bounced` (hard) / `complained` / `unsubscribed`, the ingest path SHALL upsert a `suppressions` row in the same transaction as the `message_events` insert. Soft bounces SHALL NOT auto-suppress but MAY trigger a configurable retry limit on the offending `step_execution_id`.

#### Scenario: Hard bounce upserts suppression
- **WHEN** a verified `bounced` event with `severity: "permanent"` is ingested for `recipient: "ada@example.com"`
- **THEN** in a single `Ecto.Multi` the system inserts the `message_events` row AND upserts `suppressions(channel: "email", recipient: "ada@example.com", reason: "bounce")`.

#### Scenario: Soft bounce does not suppress
- **WHEN** a `bounced` event with `severity: "temporary"` is ingested
- **THEN** no `suppressions` row is written, but the `step_executions` row's `retry_count` is incremented and dispatch retry policy applies.

### Requirement: Reply Detection Is Routed Through The Channel Adapter When Supported

When an inbound provider event includes a `reply` indicator (e.g., Mailgun's `inbound` route, SES's reply detection, Twilio's incoming SMS), the ingest path SHALL emit a `message_events` row with `event_type: "replied"` and SHALL invoke a configured `DripDrop.OnReply` callback (default: `pause_enrollment` for cold-outbound steps, no-op for transactional). Replies SHALL NOT auto-suppress.

#### Scenario: Cold outbound reply pauses enrollment
- **WHEN** a reply event maps to a `step_execution_id` whose enclosing step has `operating_mode: "cold"`
- **THEN** the enrollment transitions to `paused` and a `message_events` row with `event_type: "replied"` is recorded.

#### Scenario: Reply on transactional thread is informational
- **WHEN** the reply maps to a `transactional` step
- **THEN** the event is recorded but the enrollment state does NOT change.

### Requirement: Ingest Is Idempotent Per Provider Event Id

For providers that supply a unique event id, the ingest path SHALL store that id in `message_events.event_data["provider_event_id"]` and SHALL deduplicate via a unique partial index on `(provider, provider_event_id) WHERE provider_event_id IS NOT NULL`. Duplicate webhook deliveries SHALL be no-ops returning `200`.

#### Scenario: Duplicate webhook is a 200 no-op
- **WHEN** Mailgun retries the same event with the same `id`
- **THEN** the second insert violates the unique index, the ingest path catches the violation, returns `200`, and emits `[:dripdrop, :ingest, :duplicate]` telemetry.
