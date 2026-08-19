# DripDrop

[![Hex.pm](https://img.shields.io/hexpm/v/dripdrop.svg)](https://hex.pm/packages/dripdrop)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/dripdrop)
[![License](https://img.shields.io/hexpm/l/dripdrop.svg)](https://github.com/agoodway/dripdrop/blob/main/LICENSE)

> Drop-in sequential messaging for Elixir.

A backend-first, database-driven messaging sequence engine for Elixir. Drip onboarding, lifecycle nurture, win-back, and outbound campaigns across email, SMS, webhooks, Telegram, and other channels, with Elixir, HTTP, and predicate hooks for decision routing. Outbound mode adds sender pools, per-mailbox ramp schedules, auto-pause on reply, and message threading. Every sequence, enrollment, and delivery event lives in Postgres. Dispatch schedules through [PgFlow](https://github.com/agoodway/pgflow) by default, with Oban available for hosts that already run it.

DripDrop is for sequence/drip messaging — onboarding flows, lifecycle nurtures,
win-back campaigns, and optional cold outbound drip. Not for one-off
transactional email like password resets.

## What It Does

- Author versioned sequences with steps, timing, transitions, and conditions.
- Enroll subscribers into active sequence versions.
- Dispatch due steps through PgFlow (default) or Oban.
- Render templates with Liquid/Liquex, trusted EEx module templates, optional MJML email compilation, and opt-in deterministic spintax.
- Evaluate conditions through Predicated, enrollment data, events, Elixir hooks, and HTTP hooks.
- Send through database-stored channel adapters with encrypted credentials.
- Apply suppressions, quiet hours, rate limits, bounce/complaint thresholds, optional unsubscribe headers, and explicit sending rules.
- Normalize inbound provider webhooks into `message_events`.
- Run cold outbound versions through tenant-scoped sender pools with enrollment-time adapter pinning, ramp caps, min-gap checks, threading headers, and host-fed reply ingestion.
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
- `adapter_pools`, `adapter_pool_members`, `adapter_sequence_budgets`

Lifecycle sequences use the existing adapter-selection chain: explicit step
adapter, step or sequence rotation, tenant default, then global default. Cold
outbound sequences opt into `sequence_versions.mode = "outbound"` and resolve
senders through an adapter pool once at enrollment time. The selected adapter is
pinned on `enrollments.adapter_id`, and outbound-only gates enforce health,
ramp caps, per-sequence sub-caps, min-gap timing, and email threading headers.
Lifecycle rows leave the new fields unset and keep the foundation dispatch flow.

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
    {:dripdrop, "~> 0.2.1"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

For the full host-app setup, including scheduler migrations, runtime
configuration, schema checks, and webhook mounting, see
[`guides/installation.md`](guides/installation.md).

## Quick Start

The minimum host-app setup is:

1. Configure DripDrop with your Ecto repo, scheduler, and channel settings.
2. Generate PgFlow migrations first, then the DripDrop wrapper migration.
3. Run `mix ecto.migrate`.
4. Call `DripDrop.startup_check/0` during boot after the repo and scheduler are started.
5. Mount provider webhooks if you use webhook-delivering providers.

The canonical installation walkthrough lives in
[`guides/installation.md`](guides/installation.md). This README keeps the main
runtime shape visible:

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

```bash
mix pgflow.gen.postgres_extensions_migration   # add --no-cron if pg_cron unavailable
mix pgflow.gen.pgmq_migration
mix pgflow.setup
mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep
mix pgflow.gen.job_migration DripDrop.Jobs.CronTick

# DripDrop schema
mix dripdrop.setup --repo MyApp.Repo

# Apply everything
mix ecto.migrate
```

These PgFlow job migrations install DripDrop's generic scheduler workers once.
Sequence authoring remains dynamic: new DripDrop sequences, steps, transitions,
conditions, hooks, and enrollments do not require new PgFlow migrations.

Set `DRIPDROP_ENCRYPTION_KEY` to a base64-encoded 32-byte key before boot.
Call `DripDrop.startup_check/0` in your host `Application.start/2` callback
after the Repo, scheduler supervisor, and channel registrations are configured:

```elixir
def start(_type, _args) do
  children = [MyApp.Repo, ...]

  with {:ok, sup} <- Supervisor.start_link(children, strategy: :one_for_one),
       :ok <- DripDrop.startup_check() do
    {:ok, sup}
  end
end
```

Mount provider webhooks in a Phoenix router when needed:

```elixir
import DripDrop.Web.Router

scope "/" do
  dripdrop_webhooks("/webhooks/dripdrop")
end
```

### Author and Run a Sequence

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

### Cold Outbound Mode

Cold outbound is opt-in per sequence version. Lifecycle behavior stays the
default. To send a prospect drip from the same mailbox across every step, create
an adapter pool, add mailbox or ESP members, and set the sequence version to
`mode: :outbound` with `config["pool_id"]`.

```elixir
{:ok, pool} =
  DripDrop.create_adapter_pool(%{
    tenant_key: "acct_123",
    name: "sales_pool",
    on_pin_unavailable: :pause
  })

{:ok, _member} =
  DripDrop.add_pool_member(pool.id, %{
    adapter_id: adapter.id,
    class: :mailbox,
    weight: 1
  })

{:ok, version} =
  DripDrop.create_sequence_version(sequence.id, %{
    version: 2,
    mode: :outbound,
    config: %{"pool_id" => pool.id}
  })
```

Outbound enrollments store the selected sender in `enrollments.adapter_id`.
Follow-up email steps generate `Message-ID`, `In-Reply-To`, and `References`
headers for threading. Hosts that receive replies through IMAP, Microsoft Graph,
or Gmail API watch should normalize those messages and call
`DripDrop.ingest_inbound_message/2`. See
[`guides/cold_outbound.md`](guides/cold_outbound.md).

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

# Cold outbound (optional)
DripDrop.create_adapter_pool(attrs)
DripDrop.update_adapter_pool(pool, attrs)
DripDrop.delete_adapter_pool(pool_id, opts)
DripDrop.list_adapter_pools(%{tenant_key: tenant_key})
DripDrop.add_pool_member(pool_id, attrs)
DripDrop.remove_pool_member(member_id, tenant_key)
DripDrop.list_pool_members(pool_id)
DripDrop.set_adapter_health(adapter_id, attrs)
DripDrop.set_adapter_sequence_budget(adapter_id, sequence_version_id, attrs)
DripDrop.repin_enrollment(enrollment_id, adapter_id, opts)
DripDrop.ingest_inbound_message(adapter_id_or_scope, normalized_message)
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

Integration tests exercise the real PgFlow scheduler and are excluded from the
default test run:

```bash
mix test --only integration
```

Quality gates used by this repo:

```bash
mix quality   # compile --warnings-as-errors, format check, sobelow, doctor, credo --strict
mix dialyzer
```

CI runs the suite under Postgres 18 both with and without `pg_cron`.

## Demo App

The demo app lives in [`demo/`](demo/README.md). From the repo root, run it with
the local Hivemind wrapper:

```bash
bin/dripdrop start
bin/dripdrop stop
bin/dripdrop console
```

The wrapper runs `Procfile.dev`, starts Docker Postgres, and serves the demo at
[`localhost:4012`](http://localhost:4012). The demo includes onboarding, lead
nurture, and cold outbound scenarios using local/sandboxed channels, PubSub, and
mock HTTP hooks.

## Guides

In-depth documentation lives in the project guides:

- [`installation.md`](guides/installation.md) — full installation reference
- [`sending_rules.md`](guides/sending_rules.md) — suppressions, rate limits, thresholds
- [`lifecycle_email.md`](guides/lifecycle_email.md) — email templates, MJML, unsubscribe headers
- [`quiet_hours.md`](guides/quiet_hours.md) — per-tenant quiet hours
- [`short_links.md`](guides/short_links.md) — link rewriting and providers
- [`oauth_providers.md`](guides/oauth_providers.md) — Gmail and MS365 token callbacks
- [`cold_outbound.md`](guides/cold_outbound.md) — sender pools, ramping, threading, inbound replies
- [`operations.md`](guides/operations.md) — replay, suppression, observability
- [`extending.md`](guides/extending.md) — custom channels and short-link adapters

## Changelog

### Unreleased

- Added optional cold outbound mode with adapter pools, enrollment-time sender
  pinning, adapter health/ramp controls, min-gap enforcement, per-sequence
  sub-caps, outbound Message-ID threading, host-callable inbound reply
  ingestion, and deterministic spintax.
- Updated the initial V01 schema to include cold outbound tables and columns.
  DripDrop is still pre-production, so no separate V02 migration is maintained.

## License

MIT
