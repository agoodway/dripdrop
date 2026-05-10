# Installation

DripDrop is an Elixir library that stores its domain data in the `dripdrop`
Postgres schema and uses a host application repo.

## Requirements

DripDrop requires Elixir/OTP compatible with the project `.tool-versions`,
Postgres 18+ (for native `uuidv7()`), a host Ecto repo, and
`DRIPDROP_ENCRYPTION_KEY` set to a base64-encoded 32-byte key.

## Dependencies

Add DripDrop to the host app:

```elixir
{:dripdrop, "~> 0.1"}
```

For local path development:

```elixir
{:dripdrop, path: "../dripdrop"}
```

Optional provider packages such as Swoosh, Finch, MJML, Phoenix PubSub, Oban,
AWS SNS, ExGram, and whatsapp_sdk are loaded only when the matching provider is
used. Liquex is required for Liquid template rendering.

## Configuration

```elixir
config :dripdrop,
  repo: MyApp.Repo,
  scheduler: DripDrop.Schedulers.Pgflow,
  channels: [],
  quiet_hours_default: {8, 21},
  sms_max_chars: 1600

config :dripdrop, :pgflow,
  jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]
```

Set `DRIPDROP_ENCRYPTION_KEY` before boot. It must be a base64-encoded key
accepted by `DripDrop.Vault`.

For host apps that already run Oban, set `scheduler: DripDrop.Schedulers.Oban`
and configure the host Oban supervision tree with a `:dripdrop` queue.

## Migrations

PgFlow is the recommended scheduler. Generate PgFlow migrations first:

```bash
mix pgflow.gen.postgres_extensions_migration
mix pgflow.gen.pgmq_migration
mix pgflow.setup
mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep
mix pgflow.gen.job_migration DripDrop.Jobs.CronTick
```

`DispatchStep` is the generic worker DripDrop uses for scheduled sends.
`CronTick` seeds due cron-style DripDrop steps; keep it configured and compiled
when cron timing is enabled. For hosts without `pg_cron`, generate PgFlow
extensions with `--no-cron` and keep `CronTick` in the configured PgFlow job
list.

These are one-time scheduler/job setup migrations. DripDrop sequence authoring
is dynamic: creating new sequences, steps, transitions, conditions, hooks, or
enrollments does not require new PgFlow migrations.

Generate the DripDrop wrapper migration:

```bash
mix dripdrop.setup --repo MyApp.Repo
```

Run host migrations after scheduler migrations are present:

```bash
mix ecto.migrate
```

Use `mix dripdrop.check_schema` in CI or deploy checks to verify the installed
schema version matches the library.

## Cold Outbound

Cold outbound is optional. No extra migration is required beyond the current V01
schema. Hosts that enable outbound mode should:

1. Create mailbox or ESP adapters with health/ramp fields.
2. Create an adapter pool and add pool members.
3. Set `sequence_versions.mode = "outbound"` and `config["pool_id"]` on the
   outbound version.
4. Pump inbound mailbox replies from host-owned IMAP, Microsoft Graph, or Gmail
   infrastructure into `DripDrop.ingest_inbound_message/2`.

See [`cold_outbound.md`](cold_outbound.md) for the full operator guide.

## Webhooks

In a Phoenix router:

```elixir
import DripDrop.Web.Router

scope "/" do
  dripdrop_webhooks("/webhooks/dripdrop")
end
```

Inbound routes are registered for Mailgun, SendGrid, Postmark, MailerSend, SES,
and Twilio. Verification happens in `DripDrop.Web.WebhookPlug`; supported
providers use their native signature, basic auth, or SNS certificate checks.
Gmail, MS365, SMTP, PubSub, Slack, and Telegram treat a successful send as the
terminal positive signal.
