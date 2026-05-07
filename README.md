# DripDrop

Backend-first, database-driven messaging sequence engine for Elixir.

DripDrop lets a host app drip multi-step sequences across email, SMS, webhooks, PubSub, Slack, Telegram, and WhatsApp while keeping sequence state, policy decisions, delivery attempts, and provider events in the host database. Schedules dispatch through [PgFlow](https://github.com/agoodway/pgflow) by default, with Oban available for hosts that already run it.

DripDrop is for sequence/drip messaging — onboarding flows, lifecycle nurtures, win-back campaigns. Not for one-off transactional email like password resets.

## What It Does

- Author versioned sequences with steps, timing, transitions, and conditions.
- Enroll subscribers into active sequence versions.
- Dispatch due steps through PgFlow (default) or Oban.
- Render templates with Liquid/Liquex, trusted EEx module templates, and optional MJML email compilation.
- Evaluate conditions through Predicated, enrollment data, events, Elixir hooks, and HTTP hooks.
- Send through database-stored channel adapters with encrypted credentials.
- Apply suppressions, quiet hours, rate limits, bounce/complaint thresholds, optional unsubscribe headers, and explicit sending rules.
- Normalize inbound provider webhooks into `message_events`.
- Rewrite eligible links through GoodAnalytics, module, webhook, or no-op short-link providers.

## Why DripDrop?

- **Postgres is the source of truth** — sequences, enrollments, executions, suppressions, and message events are queryable SQL tables. Debug with `SELECT * FROM dripdrop.enrollments`.
- **No infrastructure beyond Postgres** — PgFlow runs the scheduler in your database. No Redis, no external queue.
- **Multi-tenant by default** — every domain table carries `tenant_key`. Query helpers require an explicit tenant scope (use `tenant_key: nil` for global records).
- **Provider-agnostic channels** — eight email providers, two SMS providers, plus Slack/Telegram/WhatsApp/Webhook/PubSub built in. Custom providers register through a small behaviour.
- **Encrypted credentials at rest** — channel adapter credentials are encrypted via Cloak with a host-supplied `DRIPDROP_ENCRYPTION_KEY`.

## Architecture

DripDrop owns the `dripdrop` Postgres schema through [EctoEvolver](https://github.com/agoodway/ecto_evolver) raw SQL migrations. When PgFlow is used as the scheduler, PgFlow owns its separate `pgflow` schema; DripDrop never writes PgFlow internals directly.

Current `dripdrop` tables:

- `sequences`, `sequence_versions`, `steps`, `step_transitions`, `conditions`
- `channel_adapters`, `http_hooks`
- `enrollments`, `step_executions`, `events`
- `suppressions`, `message_events`, `short_links`

Tenant scoping is represented by `tenant_key`. Query helpers that could leak tenant data require an explicit tenant scope; pass `tenant_key: nil` when intentionally querying global records. Deprecated unscoped helpers raise.

## Prerequisites

- Elixir 1.17+ / OTP 26+
- PostgreSQL 18+ (for native `uuidv7()` used by the v01 schema's UUIDv7 primary keys)
- A host Ecto repo
- A durable scheduler — PgFlow (recommended) or Oban
- `DRIPDROP_ENCRYPTION_KEY` set to a base64-encoded 32-byte key

Runtime dependencies: Ecto, Ecto SQL, Postgrex, EctoEvolver, Cloak Ecto, Req, Jason, Plug, Floki, Liquex, Nebulex local cache, Predicated, ex_phone_number, ex_email, Standard Webhooks, and PgFlow when used as the scheduler. Optional channel/provider integrations (Swoosh/Finch, MJML, Phoenix PubSub, Oban, AWS SNS, Telegram, WhatsApp SDK) are loaded only when the matching provider is used.

## Installation

Add `dripdrop` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dripdrop, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### 1. Configure DripDrop

```elixir
# config/config.exs
config :dripdrop,
  repo: MyApp.Repo,
  scheduler: DripDrop.Schedulers.Pgflow,
  channels: [],
  quiet_hours_default: {8, 21},
  sms_max_chars: 1600

config :dripdrop, :pgflow,
  jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]
```

Set `DRIPDROP_ENCRYPTION_KEY` to a base64-encoded 32-byte key before boot.

For host apps that already run Oban, use the Oban scheduler instead and configure a `:dripdrop` queue in your Oban supervision tree:

```elixir
config :dripdrop, scheduler: DripDrop.Schedulers.Oban
```

### 2. Generate Migrations

PgFlow is the recommended scheduler. Generate its migrations first, then DripDrop's:

```bash
# PgFlow setup (skip if Oban scheduler)
mix pgflow.gen.postgres_extensions_migration   # add --no-cron if pg_cron unavailable
mix pgflow.gen.pgmq_migration
mix pgflow.setup
mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep

# DripDrop schema
mix dripdrop.setup --repo MyApp.Repo

# Apply everything
mix ecto.migrate
```

For hosts without `pg_cron`, generate PgFlow extensions with `--no-cron` and include `DripDrop.Jobs.CronTick` in the configured PgFlow job list.

### 3. Validate at Boot

Call `DripDrop.startup_check/0` in your host `Application.start/2` callback after the Repo, scheduler supervisor, and channel registrations are configured. It catches missing optional deps, invalid encryption config, and scheduler registration issues:

```elixir
def start(_type, _args) do
  children = [MyApp.Repo, ...]

  with {:ok, sup} <- Supervisor.start_link(children, strategy: :one_for_one),
       :ok <- DripDrop.startup_check() do
    {:ok, sup}
  end
end
```

### 4. Mount Provider Webhooks

In a Phoenix router:

```elixir
import DripDrop.Web.Router

scope "/" do
  dripdrop_webhooks("/webhooks/dripdrop")
end
```

Inbound routes are registered for Mailgun, SendGrid, Postmark, MailerSend, SES, and Twilio. Verification happens in `DripDrop.Web.WebhookPlug`. Providers without delivery webhooks (Gmail, MS365, SMTP, PubSub, Slack, Telegram) treat a successful send as the terminal positive signal.

### 5. Author and Run a Sequence

```elixir
# Create a channel adapter (credentials are encrypted at rest)
{:ok, adapter} = DripDrop.create_channel_adapter(%{
  channel: "email",
  provider: "postmark",
  name: "Default Postmark",
  is_default: true,
  credentials: %{api_token: System.fetch_env!("POSTMARK_API_TOKEN")},
  tenant_key: nil
})

# Author a sequence and version
{:ok, sequence} = DripDrop.create_sequence(%{key: "welcome", name: "Welcome Series"})
{:ok, version} = DripDrop.create_sequence_version(sequence.id, %{version: 1})

{:ok, _step} = DripDrop.create_step(version.id, %{
  key: "day_1",
  channel: "email",
  template: %{subject: "Welcome!", html: "<p>Hi {{ subscriber.first_name }}</p>"},
  delay: %{hours: 0}
})

# Activate (archives the previously active version)
{:ok, _} = DripDrop.activate_sequence_version(version.id)

# Enroll a subscriber
{:ok, _enrollment} = DripDrop.enroll(%{
  sequence_id: sequence.id,
  subscriber_type: "user",
  subscriber_id: "user_123",
  data: %{first_name: "Sam", email: "sam@example.com"},
  tenant_key: nil
})
```

## Channels

Built-in channel providers:

| Channel  | Providers                                                       |
|----------|-----------------------------------------------------------------|
| Email    | Mailgun, SendGrid, Postmark, MailerSend, SES, SMTP, Gmail, MS365 |
| SMS      | Twilio, AWS SNS                                                 |
| Webhook  | Standard Webhooks-shaped outbound requests                      |
| PubSub   | Phoenix PubSub                                                  |
| Slack    | Incoming webhook                                                |
| Telegram | Bot API                                                         |
| WhatsApp | Cloud API                                                       |

Custom providers register with `DripDrop.Channels.register/3`. See `guides/extending.md`.

Gmail and Microsoft 365 do not own OAuth flows. The host provides a `token_callback` MFA that returns access tokens; DripDrop never stores refresh tokens or OAuth client secrets. See `guides/oauth_providers.md`.

## Public API

Common entry points exposed on the `DripDrop` module:

```elixir
# Sequence authoring
DripDrop.create_sequence(attrs)
DripDrop.create_sequence_version(sequence_id, attrs)
DripDrop.activate_sequence_version(version_id)
DripDrop.create_step(version_id, attrs)
DripDrop.create_step_transition(version_id, attrs)
DripDrop.create_condition(owner_id, attrs)
DripDrop.validate_sequence_version(version_id)

# Channel adapters
DripDrop.create_channel_adapter(attrs)
DripDrop.update_channel_adapter(adapter, attrs)
DripDrop.list_channel_adapters(%{tenant_key: tenant_key})
DripDrop.get_default_adapter(channel, tenant_key)

# HTTP hooks
DripDrop.create_http_hook(sequence_id, attrs)
DripDrop.update_http_hook(hook, attrs)
DripDrop.test_http_hook(hook_id, data)
DripDrop.list_http_hooks(sequence_id, tenant_key)

# Enrollments
DripDrop.enroll(attrs)
DripDrop.unenroll(enrollment_id, tenant_key)
DripDrop.pause_enrollment(enrollment_id, tenant_key)
DripDrop.resume_enrollment(enrollment_id, tenant_key)
DripDrop.track_event(identity, event_key, event_data)
DripDrop.list_active_enrollments(%{tenant_key: tenant_key})
DripDrop.get_enrollment(sequence_id, subscriber_type, subscriber_id, tenant_key)

# Operations
DripDrop.suppress(attrs)
DripDrop.replay(step_execution_id)
DripDrop.webhook_routes()
DripDrop.startup_check()
```

Deprecated unscoped helpers raise — pass an explicit `tenant_key` (use `nil` for global records).

## Short Links

Short-link rewriting runs after rendering and before delivery. It parses HTML with Floki, rewrites only `href` and `src`, preserves plain-text punctuation, skips sensitive/already-short links, and persists idempotent `short_links` rows.

Built-in short-link providers:

- `DripDrop.ShortLinks.GoodAnalytics`
- `DripDrop.ShortLinks.Module`
- `DripDrop.ShortLinks.Webhook`
- `DripDrop.ShortLinks.None`

Configure globally, per tenant, sequence, or step — step config wins. See `guides/short_links.md`.

## Mix Tasks

| Task                          | Description                                          |
|-------------------------------|------------------------------------------------------|
| `mix dripdrop.setup`          | Generate the wrapper migration into the host app     |
| `mix dripdrop.gen.migration`  | Generate a follow-up migration                       |
| `mix dripdrop.check_schema`   | Verify the installed schema version (CI/deploy gate) |
| `mix dripdrop.uninstall`      | Generate a teardown migration                        |

## Testing

DripDrop ships with a Docker Compose setup for the development database:

```bash
docker compose up -d
```

This starts Postgres 18 with `pg_cron` configured against `dripdrop_dev` on `localhost:54325` (user: `postgres`, password: `postgres`).

Run the test suite:

```bash
mix test
```

Quality gates used by this repo:

```bash
mix quality   # compile --warnings-as-errors, format check, sobelow, doctor, credo --strict
mix dialyzer
```

CI runs the suite under Postgres 18 both with and without `pg_cron`.

## Guides

In-depth documentation lives in [`guides/`](guides/):

- [`installation.md`](guides/installation.md) — full installation reference
- [`sending_rules.md`](guides/sending_rules.md) — suppressions, rate limits, thresholds
- [`lifecycle_email.md`](guides/lifecycle_email.md) — email templates, MJML, unsubscribe headers
- [`quiet_hours.md`](guides/quiet_hours.md) — per-tenant quiet hours
- [`short_links.md`](guides/short_links.md) — link rewriting and providers
- [`oauth_providers.md`](guides/oauth_providers.md) — Gmail and MS365 token callbacks
- [`operations.md`](guides/operations.md) — replay, suppression, observability
- [`extending.md`](guides/extending.md) — custom channels and short-link adapters

## License

MIT
