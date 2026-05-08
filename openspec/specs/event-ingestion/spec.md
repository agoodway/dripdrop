# event-ingestion

## Purpose

Event ingestion defines framework-agnostic provider webhook handling, signature verification, normalization, deduplication, and side effects.

## Requirements

### Requirement: Webhook Ingest Plug Is Mounted By The Host App

The library SHALL expose `DripDrop.Web.WebhookPlug` and a router macro `DripDrop.Web.Router.dripdrop_webhooks(path)` that mounts a single base path under which all adapter-declared inbound webhook routes resolve as subpaths. The macro SHALL be safe to mount inside any Phoenix endpoint and SHALL NOT depend on Phoenix.

#### Scenario: Mount under /webhooks
- **WHEN** the host app calls `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")`
- **THEN** Mailgun events POST to `/webhooks/dripdrop/mailgun/:adapter_id`, Twilio events POST to `/webhooks/dripdrop/twilio/:adapter_id`, etc.

### Requirement: Provider Signatures Are Verified Before Persistence

For every supported provider that ships outbound webhook events (`mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`, `twilio`), the ingest path SHALL verify the request signature using the corresponding adapter's stored credentials before any database write. Verification failure SHALL return `401` and SHALL log a `[:dripdrop, :ingest, :signature_failure]` telemetry event with `provider`, `adapter_id`, and the request id (NEVER the body or headers). Unsupported providers SHALL return `404`.

Providers whose signature includes a timestamp (`mailgun`, `ses`) SHALL additionally enforce a replay window — the signed timestamp SHALL be within `:webhook_replay_skew_seconds` (default 300) of the current clock. Replays outside the window SHALL return `401` and emit a `[:dripdrop, :webhook, :replay_window]` telemetry event with `provider`, `adapter_id`, and the offending `timestamp`. The signature check SHALL run before the replay-window check so the timestamp is authenticated before being trusted.

The SES adapter SHALL require a `sns_topic_arn` credential and SHALL reject inbound notifications whose `TopicArn` does not match. An adapter without `sns_topic_arn` SHALL fail credential validation at create time so that a missing credential never silently disables topic pinning.

Providers that do **not** push delivery events through webhooks (`gmail`, `ms365`, `smtp`, `pubsub`, `slack`, `telegram`) SHALL NOT register webhook routes. For those providers, `step_executions` transitions to `sent` on a successful API response, and downstream `delivered`/`bounced`/`complained` signals are not available — `messaging-policy` SHALL still apply suppressions on synchronous send-time errors (e.g., a 5xx Gmail response indicating a hard failure).

#### Scenario: Mailgun signature verification
- **WHEN** a Mailgun webhook hits `/webhooks/dripdrop/mailgun/<adapter_id>` with valid `timestamp`, `token`, and `signature` HMAC'd with the adapter's API key, and the signed timestamp is within the configured skew window
- **THEN** the request is accepted and an event is enqueued for processing.

#### Scenario: Invalid signature
- **WHEN** the same Mailgun webhook is sent with a tampered signature
- **THEN** the response is `401`, no `message_events` row is written, and a `signature_failure` telemetry event fires.

#### Scenario: Mailgun replay outside the skew window
- **WHEN** a Mailgun webhook arrives with a valid signature for a timestamp from two hours ago and `:webhook_replay_skew_seconds` is at the 300-second default
- **THEN** the response is `401`, no `message_events` row is written, and a `[:dripdrop, :webhook, :replay_window]` telemetry event fires.

#### Scenario: SES adapter without sns_topic_arn
- **WHEN** an operator creates an SES `channel_adapter` with `region`, `access_key`, and `secret` but no `sns_topic_arn`
- **THEN** the changeset returns `{:error, ...}` with `sns_topic_arn is required` and the adapter is not persisted.

### Requirement: Webhook Bodies Are Bounded

The ingest plug SHALL cap the inbound body size at `:webhook_max_body_bytes` (default 1 MiB) and SHALL return `413 Request Entity Too Large` for oversize requests without buffering the full body or persisting any rows. Oversize requests SHALL emit a `[:dripdrop, :webhook, :body_too_large]` telemetry event with `provider`, `adapter_id`, and `max_bytes`.

#### Scenario: Oversize body is rejected
- **WHEN** a client POSTs a 10 MiB body to `/webhooks/dripdrop/mailgun/<adapter_id>`
- **THEN** the response is `413`, no `message_events` row is written, and a `body_too_large` telemetry event fires.

### Requirement: Inbound Events Are Normalized Into `message_events`

Verified provider events SHALL be normalized into `dripdrop.message_events` rows with: `step_execution_id` (resolved by a `(tenant_key, channel, provider_message_id)` lookup, NULLABLE if no match), `channel`, `provider`, `provider_message_id`, `event_type` (`delivered | bounced | complained | opened | clicked | replied | unsubscribed | failed | rejected`), `event_data` JSONB (raw provider payload, with secrets redacted), and `occurred_at` (parsed from the provider event, falling back to `now()`).

The `step_execution_id` resolver SHALL filter by the inbound adapter's `tenant_key` and `channel` so a webhook delivered to one tenant's adapter cannot associate to another tenant's `step_execution` even when `provider_message_id` collides.

#### Scenario: Delivered event
- **WHEN** Mailgun posts a `delivered` event with `message-id: <abc@example>` matching a `step_executions.provider_message_id` row whose `tenant_key` and `channel` match the inbound adapter
- **THEN** a `message_events` row is inserted with `event_type: "delivered"`, `step_execution_id` linked, and the raw payload stored under `event_data` with redaction applied.

#### Scenario: Cross-tenant provider id collision
- **WHEN** two tenants' adapters happen to emit messages with the same `provider_message_id`, and a webhook lands on tenant A's ingest URL
- **THEN** the resolver matches only tenant A's `step_executions` row, never tenant B's, regardless of insert order or recency.

#### Scenario: Unmatched provider id
- **WHEN** an event references a `provider_message_id` not present in any `step_executions` row for the same tenant and channel
- **THEN** the event is still persisted with `step_execution_id IS NULL` so out-of-band acknowledgments are not dropped, and a `[:dripdrop, :ingest, :unmatched_event]` telemetry event fires.

### Requirement: Bounce, Complaint, And Unsubscribe Events Update Suppressions Atomically

When an event is `bounced` (hard) / `complained` / `unsubscribed`, the ingest path SHALL upsert a `suppressions` row in the same transaction as the `message_events` insert. Suppressions are tenant-scoped: each tenant has its own `(channel, recipient_normalized)` unique index, plus a separate global index for `tenant_key IS NULL` rows. A suppression for a recipient in one tenant SHALL NOT block sends to that recipient from another tenant. Soft bounces SHALL NOT auto-suppress but MAY trigger a configurable retry limit on the offending `step_execution_id`.

#### Scenario: Hard bounce upserts suppression
- **WHEN** a verified `bounced` event with `severity: "permanent"` is ingested for `recipient: "ada@example.com"` on a tenant-A adapter
- **THEN** in a single `Ecto.Multi` the system inserts the `message_events` row AND upserts `suppressions(tenant_key: "tenant-a", channel: "email", recipient: "ada@example.com", reason: "bounce")`.

#### Scenario: Suppression in one tenant does not block another
- **WHEN** tenant A holds a suppression for `ada@example.com` and tenant B dispatches a step to the same address
- **THEN** the dispatch worker queries tenant B's suppression scope, finds none, and the send proceeds.

#### Scenario: Soft bounce does not suppress
- **WHEN** a `bounced` event with `severity: "temporary"` is ingested
- **THEN** no `suppressions` row is written, but the `step_executions` row's `retry_count` is incremented and dispatch retry policy applies.

### Requirement: Reply Detection Is Routed Through The Channel Adapter When Supported

When an inbound provider event includes a `reply` indicator (e.g., Mailgun's `inbound` route, SES's reply detection, Twilio's incoming SMS), the ingest path SHALL emit a `message_events` row with `event_type: "replied"` and SHALL invoke a configured `DripDrop.OnReply` callback. The default callback pauses the enrollment only when the step sets `config["reply_behavior"] == "pause_enrollment"`; otherwise it records the event and leaves enrollment state unchanged. Replies SHALL NOT auto-suppress.

#### Scenario: Reply behavior pauses enrollment
- **WHEN** a reply event maps to a `step_execution_id` whose enclosing step has `reply_behavior: "pause_enrollment"`
- **THEN** the enrollment transitions to `paused` and a `message_events` row with `event_type: "replied"` is recorded.

#### Scenario: Reply without pause behavior is informational
- **WHEN** the reply maps to a step without pause reply behavior
- **THEN** the event is recorded but the enrollment state does NOT change.

### Requirement: Ingest Is Idempotent Per Provider Event Id

For providers that supply a unique event id, the ingest path SHALL store that id in `message_events.event_data["provider_event_id"]` and SHALL deduplicate via a unique partial index on `(provider, provider_event_id) WHERE provider_event_id IS NOT NULL`. Duplicate webhook deliveries SHALL be no-ops returning `200`.

#### Scenario: Duplicate webhook is a 200 no-op
- **WHEN** Mailgun retries the same event with the same `id`
- **THEN** the second insert violates the unique index, the ingest path catches the violation, returns `200`, and emits `[:dripdrop, :ingest, :duplicate]` telemetry.


### Requirement: Outbound RFC Message-ID Is Stored Distinctly From Provider Message ID

The system SHALL extend `dripdrop.step_executions` with a nullable `out_message_id text` column storing the RFC 5322 `Message-ID` value generated by DripDrop and stamped into outgoing email headers in outbound mode. This column SHALL be distinct from the existing `provider_message_id` (the provider's internal id) — they have different uniqueness scopes, different lifetimes, and serve different correlation purposes. Lifecycle emails SHALL leave `out_message_id IS NULL` unless `step.config["thread_continuity"] == true` opts them in (in which case lifecycle steps also generate and store an `out_message_id`).

#### Scenario: Outbound send populates out_message_id
- **WHEN** an outbound email step sends successfully through Mailgun and Mailgun returns `provider_message_id: "20260507.1234@mailgun.net"`
- **THEN** `step_executions.out_message_id` stores DripDrop's generated `<uuidv7@sending_domain>` value (e.g., `<01970000-...-...@example.com>`), and `step_executions.provider_message_id` stores `"20260507.1234@mailgun.net"`. Both are queryable independently.

#### Scenario: Lifecycle send leaves out_message_id null
- **WHEN** a lifecycle email step sends without opting into thread continuity
- **THEN** `step_executions.out_message_id IS NULL` and `step_executions.provider_message_id` is populated as today.

### Requirement: Inbound Message Events Capture RFC Threading Headers

The system SHALL extend `dripdrop.message_events` with two nullable columns: `in_reply_to text` (the inbound message's `In-Reply-To:` header value, normalized to remove angle brackets) and `references_list jsonb` (the parsed list of message ids from the inbound message's `References:` header, ordered oldest-first). Webhook ingest paths that already deliver header information SHALL populate these columns when present. The host-callable inbound API SHALL accept them as documented fields.

#### Scenario: Provider webhook inbound parse populates threading columns
- **WHEN** a Mailgun inbound parse webhook delivers an email reply with headers `In-Reply-To: <m1@dripdrop.example>` and `References: <m0@dripdrop.example> <m1@dripdrop.example>`
- **THEN** the resulting `message_events` row has `event_type = "replied"`, `in_reply_to = "m1@dripdrop.example"`, and `references_list = ["m0@dripdrop.example", "m1@dripdrop.example"]`.

#### Scenario: Non-email channels leave threading columns null
- **WHEN** an SMS provider posts a delivery webhook (Twilio status callback)
- **THEN** the `message_events` row has `in_reply_to IS NULL` and `references_list IS NULL` (these columns are email-specific).

### Requirement: Host-Callable Inbound Message Ingestion API Exists

The system SHALL expose `DripDrop.ingest_inbound_message/2` accepting `(adapter_id_or_tenant_scope, normalized_message_map)` where the second argument has shape:

```
%{
  message_id: binary() | nil,           # RFC 5322 Message-ID, no angle brackets
  in_reply_to: binary() | nil,          # parent Message-ID, no angle brackets
  references: [binary()],               # full chain, oldest-first
  from: binary(),                       # sender address
  to: binary(),                         # recipient address (the host's mailbox)
  subject: binary() | nil,
  body_text: binary() | nil,
  body_html: binary() | nil,
  received_at: DateTime.t(),
  headers: %{},                         # raw header passthrough for forensics
  intent: :reply | :ooo | :auto_reply | nil,  # optional host classification
  intent_data: %{}                      # e.g., %{return_at: ~D[2026-06-15]} for ooo
}
```

The function SHALL: (a) correlate against stored `step_executions.out_message_id` first using `in_reply_to`; (b) fall back to `step_executions.provider_message_id` matching when `out_message_id` correlation fails; (c) persist a `message_events` row with the threading metadata; (d) route to the configured `OnReply` callback (foundation's existing behavior) when `intent == :reply` or default behavior when intent is unspecified; (e) when `intent == :ooo` and `intent_data["return_at"]` is provided, schedule the enrollment's next step at that date.

#### Scenario: Host pumps an IMAP-fed reply
- **WHEN** the host calls `DripDrop.ingest_inbound_message(gmail_adapter.id, %{message_id: "abc@gmail.com", in_reply_to: "m1@dripdrop.example", from: "prospect@example.org", to: "sales@host.com", body_text: "Sure, let's chat", received_at: now(), intent: :reply})`
- **THEN** the function correlates `in_reply_to` against `step_executions.out_message_id = "m1@dripdrop.example"`, finds the originating execution, persists a `message_events` row with `event_type = "replied"`, `in_reply_to = "m1@dripdrop.example"`, and routes to `OnReply.handle_reply/2` which pauses the enrollment if the step is configured for `reply_behavior: "pause_enrollment"`.

#### Scenario: OOO intent reschedules the next step
- **WHEN** the host calls `DripDrop.ingest_inbound_message/2` with `intent: :ooo, intent_data: %{return_at: ~D[2026-06-15]}` for an inbound that correlates to an active outbound enrollment
- **THEN** the enrollment's currently-scheduled next step has its `scheduled_for` updated to `2026-06-15 09:00 enrollment-timezone` (default 9am local), an `:enrollment_event :ooo_rescheduled` is logged, and `[:dripdrop, :ingest, :ooo_rescheduled]` telemetry fires.

#### Scenario: Uncorrelated inbound is persisted but doesn't pause anything
- **WHEN** the host pumps an inbound message whose `in_reply_to` and `provider_message_id` neither match any stored outbound
- **THEN** a `message_events` row is still persisted (with `step_execution_id IS NULL`) for forensics, `[:dripdrop, :ingest, :unmatched_event]` telemetry fires (foundation-defined), and no enrollment state changes.

### Requirement: Reply Correlation Prefers RFC Message-ID Over Provider ID

When both `out_message_id` and `provider_message_id` are available for correlation against an inbound event, the system SHALL prefer `out_message_id` matching because it follows recipient-mail-client header copying behavior (RFC 5322 mandates `In-Reply-To` carries the original `Message-ID`). The `provider_message_id` fallback SHALL only execute when `out_message_id` correlation finds no match. This preserves backwards compatibility with the foundation's webhook-based correlation while adding the RFC-aligned path for IMAP/Graph/Gmail-fed replies.

#### Scenario: Webhook ingest correlates via Message-ID first
- **WHEN** a Mailgun inbound parse webhook delivers an event with `In-Reply-To: <m1@dripdrop.example>` and Mailgun's own `Message-Id: <provider_xyz@mailgun.net>` header
- **THEN** correlation matches `step_executions.out_message_id = "m1@dripdrop.example"` (the DripDrop-generated id) and ignores the provider id when the Message-ID match succeeds.

#### Scenario: Provider-id fallback for legacy webhook events
- **WHEN** a webhook event lacks an `In-Reply-To` header (older inbound parse format) but carries the original `provider_message_id`
- **THEN** correlation falls back to `step_executions.provider_message_id` matching as today, and the resulting `message_events` row has `in_reply_to IS NULL`.
