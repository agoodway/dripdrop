# channel-adapters

## Purpose

Channel adapters define database-backed delivery integrations, provider credentials, adapter selection, and the uniform channel delivery contract.

## Requirements

### Requirement: Channel Adapters Are Stored In The Database With Encrypted Credentials

The system SHALL persist `dripdrop.channel_adapters` rows with `name`, `channel` (validated against the registered channel set), `provider` (validated against the registered providers for that channel), `credentials` (encrypted at rest with `Cloak.Ecto.Map`), free-form `config` JSONB, `is_default` flag, `active` flag. The `credentials` column SHALL NEVER appear in plaintext in logs, telemetry, payload snapshots, or query results to operators without explicit decrypt.

#### Scenario: Credentials round-trip encrypted
- **WHEN** an adapter is inserted with `credentials: %{api_key: "secret"}`
- **THEN** the underlying column stores ciphertext (verified by raw SQL `SELECT credentials FROM dripdrop.channel_adapters` returning bytea), and the Ecto schema decrypts on load.

#### Scenario: Reject unknown channel
- **WHEN** an adapter is created with `channel: "fax"`
- **THEN** the changeset returns an inclusion error and no row is inserted.

#### Scenario: Reject unknown provider for known channel
- **WHEN** an adapter is created with `channel: "email", provider: "carrier_pigeon"`
- **THEN** the changeset returns `{:error, _}` because no module is registered under `DripDrop.Channels.Email.<Provider>`.

### Requirement: At Most One Default Adapter Per (Channel, Tenant) Pair

The system SHALL enforce that for a given `(channel, tenant_key)` pair, at most one `channel_adapters` row has `is_default: true`. Setting `is_default: true` on a new row SHALL atomically demote the previous default (if any) within a single transaction.

#### Scenario: Promote a new default
- **WHEN** an adapter is updated to `is_default: true` while another adapter for the same `(channel, tenant_key)` is currently default
- **THEN** the operation runs in a single transaction that flips `is_default` on both rows, ensuring zero windows of two defaults or zero defaults.

#### Scenario: Default lookup falls back to global tenant
- **WHEN** dispatch needs the default email adapter for `tenant_key: "acct_a"` but only a global default (`tenant_key IS NULL`) exists
- **THEN** the global default is selected.

### Requirement: Channel Behavior Defines A Uniform Delivery Contract

The system SHALL define a `DripDrop.Channel` behavior with a single callback `deliver(step :: %DripDrop.Step{}, enrollment :: %DripDrop.Enrollment{}, adapter :: %DripDrop.ChannelAdapter{}) :: {:ok, %{provider_message_id: binary | nil, response: map()}} | {:error, %{kind: :temporary | :permanent, reason: term()}}`. Temporary errors SHALL be retried by dispatch; permanent errors SHALL fail the execution and MAY trigger a suppression depending on the channel and reason.

#### Scenario: Temporary error retries
- **WHEN** a channel returns `{:error, %{kind: :temporary, reason: :rate_limited}}`
- **THEN** dispatch transitions the execution `sending → failed → scheduled` and re-runs after the backoff window, up to the step's max-retry budget.

#### Scenario: Permanent error suppresses
- **WHEN** the email channel returns `{:error, %{kind: :permanent, reason: {:hard_bounce, "550 5.1.1"}}}`
- **THEN** dispatch writes a `suppressions` row with `reason: "bounce"` and `recipient` set to the normalized address, and the execution transitions to `failed` without further retries.

### Requirement: Built-in Channels Cover Email, SMS, Webhook, PubSub, Slack, Telegram

The library SHALL ship six channel modules conforming to `DripDrop.Channel`:

- `DripDrop.Channels.Email` with built-in providers `mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`, `smtp`, `gmail` (Gmail API, single-mailbox), and `ms365` (Microsoft Graph `sendMail`, single-mailbox) — all delivered through `Swoosh` where a Swoosh adapter exists, otherwise direct via `Req`. The channel SHALL apply RFC 8058 headers when `messaging-policy` requires.
- `DripDrop.Channels.SMS` (providers: `twilio`, `aws_sns`).
- `DripDrop.Channels.Webhook` (no provider distinction; method, headers, body templated; outbound requests are signed with Standard Webhooks headers).
- `DripDrop.Channels.PubSub` (broadcasts via `Phoenix.PubSub`).
- `DripDrop.Channels.Slack` (provider: `webhook` for incoming webhook URLs).
- `DripDrop.Channels.Telegram` (provider: `bot_api`).

Each module SHALL expose `validate_credentials/1 :: :ok | {:error, [{atom(), binary()}]}` used by the adapter changeset.

#### Scenario: MailerSend adapter sends via Swoosh
- **WHEN** an email step is dispatched through a MailerSend adapter and `:swoosh` + the `Swoosh.Adapters.MailerSend` adapter are loaded
- **THEN** `DripDrop.Channels.Email.MailerSend` builds a `%Swoosh.Email{}`, sends through that Swoosh adapter, and maps the response into the uniform return shape — including the MailerSend `X-Message-Id` if present.

### Requirement: OAuth-Backed Providers Receive Tokens Through A Host-Supplied Callback, Never Through DripDrop's OAuth Code

For providers that require an OAuth bearer token to send (`gmail`, `ms365`), DripDrop SHALL NOT implement OAuth flows, token refresh, consent screens, or token storage. Instead, the adapter's `credentials` map SHALL accept a `token_callback` field of type `{module(), atom()}` (an MFA pair without args; called as `Module.function(adapter)`) that returns `{:ok, %{access_token: binary(), expires_at: DateTime.t()}} | {:error, term()}`. The host application owns acquisition, persistence, and refresh of those tokens. The adapter SHALL invoke the callback before each send, MAY cache the returned token in process state until `expires_at`, and SHALL surface callback errors as `{:error, %{kind: :temporary | :permanent, reason: {:token_callback, _}}}`.

The contract SHALL remain agnostic to the host's OAuth implementation. DripDrop documentation MAY reference [Tango](https://github.com/agoodway/tango) as a canonical companion library that satisfies the contract in roughly ten lines, but Tango SHALL NOT be a `mix.exs` dependency (hard, soft, or optional) of `:dripdrop`.

#### Scenario: Gmail send with a fresh token
- **WHEN** a Gmail adapter is configured with `credentials: %{token_callback: {MyApp.GmailTokens, :get}, user_email: "ada@example.com"}` and `MyApp.GmailTokens.get/1` returns `{:ok, %{access_token: "ya29...", expires_at: ~U[2026-05-06 13:00:00Z]}}`
- **THEN** `DripDrop.Channels.Email.Gmail` calls the Gmail API `users.messages.send` endpoint with `Authorization: Bearer ya29...`, sets the `From:` header to `user_email`, and returns `{:ok, %{provider_message_id: <gmail message id>}}`.

#### Scenario: Token callback returns a temporary error
- **WHEN** `MyApp.GmailTokens.get/1` returns `{:error, :rate_limited}`
- **THEN** the adapter returns `{:error, %{kind: :temporary, reason: {:token_callback, :rate_limited}}}` and dispatch retries per the step's retry policy.

#### Scenario: Token callback returns a permanent error
- **WHEN** `MyApp.GmailTokens.get/1` returns `{:error, :revoked}` or `{:error, :no_refresh_token}`
- **THEN** the adapter returns `{:error, %{kind: :permanent, reason: {:token_callback, :revoked}}}`, the execution transitions to `failed` without retry, and an operator-visible telemetry event `[:dripdrop, :channel, :token_unavailable]` fires with `provider: :gmail | :ms365` and `adapter_id`.

#### Scenario: MS365 send through Microsoft Graph
- **WHEN** an MS365 adapter is configured with `credentials: %{token_callback: {MyApp.MsGraphTokens, :get}, user_email: "ada@contoso.com"}` and the callback returns a valid token
- **THEN** `DripDrop.Channels.Email.Ms365` POSTs to `https://graph.microsoft.com/v1.0/users/<user_email>/sendMail` with the Graph payload shape, returns `{:ok, %{provider_message_id: <internet message id> | nil}}`, and never touches OAuth endpoints.

### Requirement: Custom Email Providers Are A First-Class Extension Path

The system SHALL support host-defined email providers via `DripDrop.Channels.register/3` that takes a `channel`, a provider key (atom), and a module implementing the channel-provider contract (`deliver/3`, `validate_credentials/1`, `verify_signature/2`, `webhook_routes/1`). Once registered, custom providers SHALL be accepted by `channel_adapters` validation as if they were built-in.

#### Scenario: Register a Resend custom provider
- **WHEN** the host defines `MyApp.Channels.Email.Resend` implementing the contract and calls `DripDrop.Channels.register(:email, :resend, MyApp.Channels.Email.Resend)` in `Application.start/2`
- **THEN** `DripDrop.create_channel_adapter(%{channel: "email", provider: "resend", credentials: %{...}})` succeeds, and dispatch routes through that module.

#### Scenario: Swoosh email path
- **WHEN** an email step is dispatched via a Mailgun adapter and Swoosh is loaded
- **THEN** `DripDrop.Channels.Email` builds a `%Swoosh.Email{}`, sends it through the provider's Swoosh adapter, and maps the response into the uniform return shape.

#### Scenario: Swoosh missing
- **WHEN** an email step is dispatched but the host app has not added `:swoosh` to deps
- **THEN** dispatch returns `{:error, %{kind: :permanent, reason: :swoosh_missing}}` at compile or boot time (not at first send).

### Requirement: Adapter Selection Order Is Step → Sequence → Tenant Default → Global Default

When a step has `channel_adapter_id` set, the system SHALL use that adapter. Otherwise, when the sequence's `metadata.channel_adapters[<channel>]` specifies an adapter id, the system SHALL use that. Otherwise, the system SHALL use the `(channel, tenant_key)` default; if none, the global default; if none, dispatch SHALL fail with `{:error, %{kind: :permanent, reason: :no_adapter}}`.

#### Scenario: Step override wins
- **WHEN** the step has `channel_adapter_id: sendgrid_id` and the channel default is `mailgun_id`
- **THEN** dispatch uses SendGrid.

#### Scenario: No adapter available
- **WHEN** the step omits an adapter id, the sequence omits one, and no default exists
- **THEN** dispatch fails with `:no_adapter` and the execution transitions to `failed`.

### Requirement: Weighted Adapter Rotation Is Supported At Sequence Or Step Scope

The system SHALL support weighted rotation across multiple adapters for a single channel via `step.config["channel_adapter_rotation"]` (list with `[%{adapter_id, weight}]` or simple list for round-robin) or `sequence.metadata["channel_rotation"]`. Rotation selection SHALL be deterministic for a given `step_execution_id` so retries hit the same adapter.

#### Scenario: Sticky retry adapter
- **WHEN** a step is configured for rotation across `[mailgun:70, sendgrid:30]` and the first attempt selected SendGrid
- **THEN** the retry of the same `step_execution_id` selects SendGrid again rather than re-rolling.

#### Scenario: Different step executions in the same enrollment select independently
- **WHEN** an enrollment has executed step 1 on adapter SendGrid (chosen via rotation) and step 2 is dispatched for the same enrollment with the same rotation configuration
- **THEN** step 2 receives a fresh `step_execution_id` and rotation re-rolls independently — step 2 MAY select Mailgun even though step 1 used SendGrid. This is the documented lifecycle behavior; sequences that require a single sender per recipient (for thread continuity, deliverability reputation, or other reasons) MUST configure that explicitly through other capabilities rather than relying on rotation determinism.

### Requirement: Adapters May Expose Provider-Specific Webhook Routes

Each channel adapter SHALL declare zero or more inbound webhook routes via `DripDrop.Channel.webhook_routes/1`, returning a list of `{method, path_suffix, handler}` tuples that the host app mounts. The handler SHALL parse provider events into a normalized shape consumed by the `event-ingestion` capability.

#### Scenario: Mailgun webhook route declared
- **WHEN** a host app calls `DripDrop.Web.webhook_routes()` to enumerate adapter routes
- **THEN** the list includes Mailgun's `{:post, "/mailgun/:adapter_id", DripDrop.Channels.Email.Mailgun.WebhookHandler}` plus equivalents for SendGrid/Postmark/Twilio.


### Requirement: Channel Adapters Carry Optional Health State And Ramp Configuration Columns

The system SHALL extend `dripdrop.channel_adapters` with the following nullable columns: `health_state` (text, one of `active | resting | probing | ramping`, default `NULL`), `health_score` (numeric in `[0, 1]`, default `NULL`), `resting_until` (timestamptz, default `NULL`), `last_send_at` (timestamptz, default `NULL`), `daily_cap` (integer, CHECK > 0, default `NULL`), `ramp_started_at` (timestamptz, default `NULL`), `ramp_increment` (integer, CHECK > 0, default `NULL`), `ramp_floor` (integer, CHECK >= 0, default `NULL`), `min_gap_seconds` (integer, CHECK >= 0, default `NULL`). Adapters that leave these columns NULL SHALL behave identically to today (lifecycle dispatch path is unchanged). Outbound-mode dispatch gates SHALL short-circuit (treat as "no constraint") when their corresponding column is NULL.

#### Scenario: Lifecycle adapter ignores new columns
- **WHEN** a channel adapter has all new columns NULL (the default for adapters created without specifying outbound config)
- **THEN** dispatch routes through the existing selection chain, no health/ramp/min-gap gates fire, and behavior is byte-identical to the foundation specification.

#### Scenario: Outbound adapter populates all columns
- **WHEN** an operator creates an adapter with `daily_cap: 30, ramp_started_at: now(), ramp_increment: 2, ramp_floor: 5, min_gap_seconds: 90, health_state: "ramping"`
- **THEN** the row is inserted, the dispatcher reads these columns when this adapter is selected for an outbound-mode enrollment, and the corresponding gates engage.

### Requirement: Adapter Health State Machine Has Four States With Documented Transitions

The system SHALL implement a state machine over `health_state` with allowed transitions: `NULL → active`, `NULL → ramping`, `active → resting`, `ramping → active`, `ramping → resting`, `resting → probing`, `probing → ramping`, `probing → resting`, `active → NULL` (operator manual reset). Transitions SHALL be triggered by: (a) `BounceComplaintThresholds` GenServer breaches → `→ resting` with `resting_until = now() + cooldown`; (b) automatic recovery when `resting_until` passes → `resting → probing` on the next dispatch attempt; (c) probe-phase success (no breach in 24h with at least N sends) → `probing → ramping`; (d) probe-phase failure → `probing → resting` with exponential backoff applied to next cooldown. Manual transitions via `DripDrop.set_adapter_health/2` SHALL be permitted from any state to any state with audit-event logging.

#### Scenario: Threshold breach moves adapter to resting
- **WHEN** the `BounceComplaintThresholds` checker detects `bounce_rate >= 0.02` for an adapter
- **THEN** the adapter transitions to `health_state = "resting"`, `resting_until = now() + 24h` (default cooldown), `[:dripdrop, :health, :state_changed]` telemetry fires with `from: "active", to: "resting", reason: "bounce_threshold"`, and the dispatcher excludes the adapter from pool selection until `resting_until` passes.

#### Scenario: Probe phase verifies recovery
- **WHEN** an adapter's `resting_until` has passed and a new outbound dispatch attempts to use the pool
- **THEN** the adapter transitions to `probing`, the dispatcher allows up to a configurable probe budget (default 5 sends per 24h), and on completion of the probe window without threshold breach the adapter transitions to `ramping` with `ramp_started_at = now()`.

#### Scenario: Repeat breach applies exponential backoff
- **WHEN** an adapter that recently exited `resting` (within 7 days) breaches threshold again
- **THEN** the next `resting_until` cooldown is doubled from the prior cooldown (24h → 48h → 7d, capped); telemetry includes `breach_count` and `cooldown_seconds`.

### Requirement: Ramp-Up Cap Is Applied As Linear Function Of Days Since Ramp Start

For adapters with `ramp_started_at`, `ramp_increment`, and `ramp_floor` populated, the system SHALL compute the effective daily cap as `effective_cap_today(adapter) = min(adapter.daily_cap, ramp_floor + days_elapsed * ramp_increment)` where `days_elapsed = max(0, floor((now() - ramp_started_at) / 1 day))`. Adapters in `health_state = "probing"` SHALL use a fixed probe-phase cap (default 5/day) instead of the ramp formula. Adapters with no ramp configuration (NULL ramp columns) SHALL use `daily_cap` directly when set, or no daily cap at all when both `daily_cap` and ramp columns are NULL.

#### Scenario: Linear ramp climbs to daily_cap over time
- **WHEN** an adapter has `daily_cap: 50, ramp_started_at: now() - 10 days, ramp_increment: 2, ramp_floor: 5`
- **THEN** `effective_cap_today = min(50, 5 + 10 * 2) = min(50, 25) = 25`.

#### Scenario: Mature adapter caps at daily_cap ceiling
- **WHEN** an adapter has `daily_cap: 50, ramp_started_at: now() - 30 days, ramp_increment: 2, ramp_floor: 5`
- **THEN** `effective_cap_today = min(50, 5 + 30 * 2) = min(50, 65) = 50`.

#### Scenario: Probing adapter uses fixed probe cap
- **WHEN** an adapter has `health_state = "probing"` regardless of ramp configuration
- **THEN** the effective cap for the probe day is the configured probe budget (default 5), and ramp resumes when `probing → ramping` transition occurs.

### Requirement: Min-Gap-Between-Sends Is A Cross-Sequence Per-Adapter Constraint

For adapters with `min_gap_seconds` populated, the system SHALL refuse to dispatch a new send when `now() - last_send_at < min_gap_seconds`, deferring the execution by transitioning back to `scheduled` with `scheduled_for = last_send_at + min_gap_seconds`. The constraint SHALL apply across all sequences using the adapter (not per-sequence). The `last_send_at` column SHALL be updated atomically with `step_execution.state = "sent"` transition.

#### Scenario: Min-gap respected across sequences
- **WHEN** adapter `gmail_a` has `min_gap_seconds: 90` and was last used at 10:00:00 by sequence A; sequence B attempts to dispatch through `gmail_a` at 10:00:30
- **THEN** sequence B's execution defers to 10:01:30, emits `[:dripdrop, :policy, :min_gap]` telemetry with `gap_remaining_seconds: 60`, and does NOT call the channel adapter.

#### Scenario: Lifecycle adapter without min_gap dispatches normally
- **WHEN** adapter `mailgun_a` has `min_gap_seconds = NULL` (lifecycle default)
- **THEN** the min-gap gate short-circuits and dispatch proceeds without deferral, regardless of how recently the adapter was used.

### Requirement: Outbound Adapter Selection Bypasses The Existing `is_default` Chain

When the dispatcher resolves an adapter for a step whose enclosing enrollment has `effective_mode == "outbound"`, the system SHALL: (a) read `enrollments.adapter_id`; (b) verify the adapter is still active and not in terminal `resting` state; (c) use that adapter directly. The `step.channel_adapter_id → step rotation → sequence rotation → tenant default → global default` chain from the foundation specification SHALL NOT execute for outbound-mode enrollments. Lifecycle (`effective_mode IS NULL` or `effective_mode == "lifecycle"`) enrollments continue to use the existing chain unchanged.

#### Scenario: Outbound enrollment uses pinned adapter for every step
- **WHEN** an outbound enrollment with `adapter_id: gmail_a.id` dispatches step 1, step 2, and step 3
- **THEN** all three executions resolve to `gmail_a` and the existing rotation/default chain is bypassed.

#### Scenario: Lifecycle enrollment unaffected by outbound selection logic
- **WHEN** a lifecycle enrollment (no `effective_mode` set) dispatches a step
- **THEN** the foundation's `step → step rotation → sequence rotation → tenant default → global default` chain executes exactly as documented, with no outbound-mode side effects.
