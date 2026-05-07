## Why

Elixir applications that need behavioral, multi-step messaging across email, SMS, webhooks, in-app, and chat platforms today either bolt brittle scheduling onto an email library, build one-off Oban pipelines, or pull in a hosted SaaS. None of those preserves the host application's data ownership while delivering a database-driven sequence engine with versioning, branching, suppression/consent, and a durable dispatch boundary. DripDrop fills that gap as a backend-first, schema-isolated library that any Elixir/Phoenix app can drop in.

## What Changes

- New library `:dripdrop` that owns its own Postgres schema (`dripdrop`) via `ecto_evolver` raw SQL migrations.
- Public API for authoring sequences (sequences, versions, steps, branching transitions, conditions) and managing channel adapters and hooks.
- Enrollment lifecycle API: `enroll/1`, `unenroll/3`, `pause_enrollment/1`, `resume_enrollment/1`, `track_event/3`.
- Durable dispatch boundary: PgFlow-backed `DripDrop.Jobs.DispatchStep` that claims due `step_executions` via compare-and-set, evaluates conditions, applies messaging policy, renders templates, runs short-link rewriting, sends through a channel adapter, persists provider results, and advances state. Idempotent retries.
- Six built-in channel adapters (email, SMS, webhook, PubSub, Slack, Telegram) with DB-stored credentials encrypted via Cloak; multiple adapters per channel with default and weighted rotation. Email ships eight providers — `mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`, `smtp`, `gmail` (Gmail API), `ms365` (Microsoft Graph) — plus a first-class `DripDrop.Channels.register/3` extension path for custom providers (Resend, internal ESPs, etc.). For OAuth-backed providers (`gmail`, `ms365`), the host owns the OAuth flow entirely; DripDrop only consumes a host-supplied `token_callback` MFA that returns a fresh access token before each send. **OAuth flows, consent, and refresh logic are explicitly out of scope.**
- Hooks for dynamic data and conditions: Elixir module behavior **and** HTTP hooks (encrypted auth) with bounded timeouts and per-execution caching.
- Template rendering pipeline: Liquid/Liquex (default for user-authored), MJML (responsive HTML), EEx (trusted module templates only).
- Pluggable short-link providers (GoodAnalytics, Module, Webhook, None) with idempotent generation and HTML/text-safe rewriting. Hosted shortener APIs (Dub, Bitly, Rebrandly, etc.) integrate via the Webhook adapter — no built-in adapter is shipped per provider.
- Messaging policy as a first-class concern: suppressions, consent, RFC 8058 one-click unsubscribe headers, quiet hours / timezone awareness, per-adapter / per-domain / per-recipient rate limits, bounce/complaint thresholds (≤0.3 % complaint, ≤2 % bounce on 30-day rolling).
- Event ingestion: normalized provider webhook intake into `message_events`, with auto-suppression on bounce/complaint/unsubscribe.
- Optional multi-tenancy via `tenant_key` scoping that is honored by every capability when present.
- A single `demo/` Phoenix LiveView application living next to the library (path-dep on `..`), three scenario LiveViews mirroring the README examples (Onboarding, Lead Nurture, Multi-Channel Trial), a simple **read-only** in-app dashboard (sequences/enrollments/executions/recent message events), a top-level `Dockerfile` + `docker-compose.yml` mirroring `pgflow`'s setup (Postgres 18 + pgmq + pg_cron pre-installed), and `mix demo.seed` fixtures.
- Mix tooling that mirrors pgflow's posture: `mix dripdrop.setup` (wraps schema migration; accepts `--no-cron`), `mix dripdrop.check_schema` (verify migrations are applied), `mix dripdrop.uninstall`. Quality tooling alias `mix quality` running `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow`, `ex_dna`, `doctor`, `credo --strict`. Cloak key rotation is intentionally NOT shipped as a Mix task — hosts use Cloak's standard rotation flow in their own scripts.
- **NOT in this change** (deferred to follow-on changes): a full editable LiveView dashboard (the demo's read-only views are the placeholder), AI template builder, advanced retention/redaction policies, pgflow alternative scheduler beyond the Oban shim.

## Capabilities

### New Capabilities

- `sequence-authoring`: Sequences, sequence versions (draft/active/archived), steps with embedded timing config, branching `step_transitions`, and `conditions` that reference hooks/event/enrollment-data. References — but does not own — `http_hooks`.
- `enrollment-lifecycle`: Enroll polymorphic subscribers (`subscriber_type` + opaque string `subscriber_id`), enrollment state machine (active/paused/completed/cancelled), `track_event/3`, idempotent re-enrollment guard.
- `dispatch-execution`: PgFlow-backed orchestrator. Owns `step_executions`, idempotency keys, claim-via-CAS, retry policy, transition evaluation, scheduler abstraction. Does **not** own template rendering, channel sending, hook evaluation, or policy decisions — it invokes those collaborators.
- `channel-adapters`: DB-stored `channel_adapters` with Cloak-encrypted credentials, channel behavior (`DripDrop.Channel`), built-in providers for email (Mailgun/SendGrid/Postmark via Swoosh), SMS (Twilio/AWS SNS), webhook (Req signed with Standard Webhooks), Phoenix PubSub, Slack incoming webhooks, Telegram bot API. Default adapter selection and weighted rotation.
- `hooks`: Elixir hook module behavior (`DripDrop.HookBehavior`) and HTTP hooks (`http_hooks` table, encrypted auth, JSONPath response extraction). Bounded per-hook timeout, per-execution result caching, structured error contract.
- `templates`: Liquid/Liquex as the default user-authored engine, MJML→HTML for responsive email, EEx for trusted module templates only. Shared variable resolver fed by enrollment data + hook results.
- `short-links`: `DripDrop.ShortLinks.Adapter` behavior with built-in providers (GoodAnalytics, Module, Webhook, None). Post-render pipeline: extract eligible URLs, enrich with UTM/tracking, idempotently create short links keyed by `(execution, original, destination, provider, config)`, rewrite HTML and text safely, persist `short_links` rows.
- `messaging-policy`: Suppression and consent gating (per channel + normalized recipient), optional RFC 8058 List-Unsubscribe / List-Unsubscribe-Post headers, quiet-hours and timezone enforcement (TCPA 8 AM–9 PM recipient-local for SMS), per-adapter / per-provider / per-domain / per-recipient rate limits, bounce/complaint thresholds with auto-suppression, explicit sending-rule controls, audit snapshots.
- `event-ingestion`: Normalized provider webhook intake (`Plug` + adapter callbacks) into `message_events`, mapping bounces/complaints/unsubscribes to suppressions and optionally pausing/cancelling enrollments. Reply detection where adapter supports it.
- `demo-app`: A `demo/` Phoenix 1.8 + LiveView application that consumes `:dripdrop` as a path dep and exercises the library end-to-end. Ships the three README scenarios as scenario LiveViews, a simple read-only in-app dashboard (sequences / enrollments / executions / recent message events), a `mix demo.seed` task, plus the top-level Postgres-with-extensions Docker image and `docker-compose.yml` mirroring pgflow's posture.

### Modified Capabilities

(none — DripDrop ships no prior specs)

## Impact

- **Code**: New library at `lib/dripdrop/**`, new tests at `test/dripdrop/**`, mix tasks under `lib/mix/tasks/dripdrop.*`. New `demo/` Phoenix LiveView app at the repo root (path-dep on `..`).
- **APIs**: Top-level `DripDrop.*` public API (sequences, adapters, hooks, enrollment, events). Behaviors: `DripDrop.Channel`, `DripDrop.HookBehavior`, `DripDrop.Scheduler`, `DripDrop.ShortLinks.Adapter`.
- **Database**: Owned schema `dripdrop` (created by `ecto_evolver` versioned migration `V01`); host app must run `pgflow`'s `gen.postgres_extensions_migration` and `gen.pgmq_migration` first (or run with `--no-cron` for hosts without pg_cron). Tracking object: `dripdrop.dripdrop_version` view.
- **Dependencies**: hard — `ecto`, `ecto_sql`, `postgrex`, `pgflow`, `ecto_evolver`, `crontab`, `cloak_ecto`, `req`, `jason`, `plug`, `floki`, `liquex`, `nebulex`, `nebulex_local`, `standard_webhooks`. Optional — `swoosh` + `finch`, `mjml`, `phoenix_pubsub`, `oban`, `ex_aws_sns`, `ex_gram`, `whatsapp_sdk`. Quality (dev/test only) — `credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`. Future-optional — `req_llm`, `zoi`, `phoenix_live_view` (full dashboard change).
- **Repo-root assets**: `Dockerfile` and `docker-compose.yml` shipping a Postgres 18 image with pg_cron preloaded; pgmq and pgflow are installed through PgFlow-generated migrations. Used both by the demo app and by CI.
- **Host-app responsibilities**: provide a `Repo`, run `mix dripdrop.setup`, configure `DRIPDROP_ENCRYPTION_KEY`, register a host PgFlow with `DripDrop.Jobs.DispatchStep`, configure SPF/DKIM/DMARC for any sending domains, mount `DripDrop.Web.Router.dripdrop_webhooks/1`, supply `unsubscribe_url_builder`.
- **Operational**: New worker pool (PgFlow-managed), new webhook ingest endpoint, audit log retention on `message_events` and rendered payload snapshots.
- **Out of scope for this change**: full editable dashboard UI, AI template generation, fine-grained retention/redaction config, multi-region replication.
