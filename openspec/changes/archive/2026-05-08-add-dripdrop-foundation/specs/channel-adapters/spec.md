## ADDED Requirements

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
