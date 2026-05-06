## Context

DripDrop is a fresh repository — no prior code, no prior specs. The README defines the architecture in detail; the role of this design doc is to lock in the technical decisions that turn that architecture into nine well-bounded capabilities, and to surface the cross-cutting concerns (tenancy, idempotency, encryption, schema isolation) that don't fit neatly inside any single capability.

Stakeholders: the eventual host applications that will mount DripDrop — both single-tenant SaaS apps (one set of sequences) and multi-tenant platforms (per-account sequences). Operators of those host apps care most about deliverability, audit fidelity, and not corrupting their primary marketing-domain reputation; product teams care about the authoring API and the dashboard.

Constraints carried over from the README:
- PostgreSQL 17+ with `pgmq`; `pg_cron` strongly preferred but optional.
- Schema isolation: `dripdrop` for messaging domain, `pgflow` for runtime — DripDrop must never write to `pgflow` directly.
- Cloak-encrypted credentials.
- Idempotent dispatch (workers can crash mid-send without producing duplicates).
- Multi-tenant where the host opts in via `tenant_key`.
- No required UI — dashboard is opt-in via router macro, AI builder is gated on optional deps.

## Goals / Non-Goals

**Goals:**
- Make a small library that any Phoenix app can drop in and start enrolling subscribers within a day.
- Keep the dispatch boundary unmistakable: nothing outside `DripDrop.Jobs.DispatchStep` touches `step_executions.state`.
- Treat suppression, RFC 8058 unsubscribe headers, quiet hours, and rate limiting as first-class — not afterthoughts in adapters.
- Idempotency you can defend: every outgoing message has a stable key, and every retry is a no-op or a continuation.
- Pluggable everywhere it matters (scheduler, channel adapter, hook, short-link, template engine), opinionated everywhere else.
- Observable: telemetry on every dispatch phase, condition decision, hook invocation, and provider event.

**Non-Goals (this change):**
- A full editable LiveView dashboard. The demo's read-only views are the placeholder; a dedicated dashboard with sequence editing, adapter management, hook testing UI, etc. is deferred to `add-dripdrop-dashboard` once the core API is stable.
- AI template builder. Defer to `add-ai-template-builder` (optional deps).
- Multi-region or eventually-consistent replication.
- Drop-in compatibility with Customer.io / Braze APIs.
- Inbound message processing beyond reply detection (no full IMAP/SMTP receive loop).
- Per-tenant key rotation / per-tenant Cloak keys (one global key for v1; rotation supported as a bulk re-encrypt pass).
- A built-in retention scheduler. Operators can write SQL or run an external cron. A `DripDrop.Retention` module ships in a follow-on change.

## Decisions

### D1. Two Postgres schemas, never co-mingled

`dripdrop.*` for the messaging domain. `pgflow.*` for the runtime. DripDrop reads `pgflow.runs.id` only via opaque IDs stored in `step_executions.pgflow_run_id`. Migrations for each schema live in their own library. **Why:** keeps DripDrop's evolver migrations small and auditable, and it keeps the door open for swapping PgFlow for Oban without touching the messaging schema. **Alternative considered:** single combined schema. Rejected — couples the two libraries' release cadences and complicates host-app upgrades.

### D2. Dispatch is an orchestrator, not a feature box

The `dispatch-execution` capability owns claim-and-state, idempotency keys, and the scheduler abstraction — but every other moving part (policy, hooks, templates, short-links, channel send) lives in its own capability and is invoked through a small set of internal contracts. **Why:** codex flagged the original "dispatch owns everything" sketch as a god-module risk. Splitting it forces clean seams and makes each piece testable in isolation. **Alternative:** one big "engine" module. Rejected — code review experience would be miserable, and the temptation to bypass policy in a hot path would be constant.

### D3. Idempotency key formula is part of the public contract

`idempotency_key = sha256("dripdrop:#{enrollment_id}:#{step_id}:#{trunc(scheduled_for, :minute)}:#{attempt_window}")` where `attempt_window` is bumped only on operator-initiated reset. **Why:** the formula is observable (operators can recompute it), it absorbs sub-minute clock skew without colliding across distinct schedules, and it's stable across worker restarts. We pass this same key to providers that support `Idempotency-Key` (Stripe-style — Mailgun, Postmark, Twilio). **Alternative:** UUID per row. Rejected — a row that has to be re-inserted (e.g., a manual replay) would get a new key, defeating provider-side dedup.

### D4. PgFlow as default scheduler, with a Scheduler behavior for swap-out

Default `DripDrop.Schedulers.Pgflow` calls `PgFlow.enqueue/2` with `%{step_execution_id: id}` and lets PgFlow manage retries/backoff/visibility. `DripDrop.Schedulers.Oban` ships as a fallback for hosts already on Oban. The behavior is two callbacks, `schedule/2` and `cancel/1`. **Why:** PgFlow's pgmq foundation is the right primitive (transactional enqueue, durable claim, no separate broker), but locking the library to it would alienate every host that already has Oban running. **Alternative:** native PgFlow only. Rejected as too prescriptive for v1.

### D5. Cron timing uses pg_cron when available, falls back to a tick job

When `pg_cron` is installed, `mix dripdrop.setup` registers a SQL function that, every minute, scans active sequences with cron-typed steps and inserts due `step_executions`. When unavailable, `DripDrop.Jobs.CronTick` (a PgFlow job) does the same scan from the BEAM. **Why:** pg_cron is more reliable (runs even if no Elixir node is up) and pushes the load to the DB; the Elixir tick is a workable fallback for hosts on managed Postgres without pg_cron. **Alternative:** Quantum. Rejected — Quantum schedules in-memory and loses jobs across deploys without an external persistence layer.

### D6. One Cloak vault, one key, with a documented rotation path

`DripDrop.Vault` reads `DRIPDROP_ENCRYPTION_KEY` (base64 AES-256). All encrypted columns use `Cloak.Ecto.Map`. Rotation is a documented `mix dripdrop.rotate_key` task that re-encrypts in batches. **Why:** Cloak is the de-facto standard, AES-256-GCM is the right cipher, and per-tenant keys add complexity that isn't justified for v1. **Risk:** a single compromised key exposes all credentials — partially mitigated by the no-secrets-in-logs rule and by treating the env var with the same rigor as the DB password.

### D7. `tenant_key` is a column on every domain table that needs scoping

Tables that scope to a tenant: `sequences`, `channel_adapters`, `suppressions`, `short_links` (via execution), `enrollments` (via sequence). `step_executions`, `message_events`, and `events` denormalize `tenant_key` for query performance. Every public API takes an optional `tenant_key` and refuses operations across tenants. **Why:** simpler than a `tenants` table and avoids leaking foreign keys into a host-owned concept. **Alternative:** Postgres row-level security per session. Rejected for v1 — RLS is hard to test and hard to debug; we revisit when a host asks for it.

### D8. Liquid (Solid) is the default user-authored template engine; EEx is module-only

User-authored Liquid runs with strict mode off (missing variables are empty strings); EEx never sees user input. **Why:** Liquid syntax is the established lingua franca for marketing templates, and Solid's strict mode means we can render unknown variables as empty without exposing untrusted code paths. EEx in user input is a remote-code-execution vector — not negotiable. **Alternative:** Mustache (no logic) or Tera (Rust). Both rejected — Liquid is what users expect; Tera is a binary dependency we don't need.

### D9. Suppression is keyed on normalized recipient and is the universal precondition

Email lower-cased; phone E.164; webhook URL exact; Slack/Telegram by stable channel-id. Suppression is checked in `messaging-policy` BEFORE any send-side work (template render, short-link). **Why:** if we're going to suppress, we should pay zero outbound bandwidth or third-party API calls. **Alternative:** check after render. Rejected — wastes the per-execution provider quota for short-link providers and renders sensitive data we then drop.

### D10. RFC 8058 headers are added by `messaging-policy`, not by `channel-adapters`

Each adapter still sends the raw `Swoosh.Email`, but the headers are appended in a shared policy step before the adapter sees the message. **Why:** keeps the deliverability rules in one place; an adapter author can't accidentally omit them. The unsubscribe URL builder is a host-supplied function (`unsubscribe_url_builder: {Mod, :fun, 1}`) so the host controls signing/routing.

### D11. Short-link generation runs after template render but before channel send

The pipeline is: render → policy gate (including unsubscribe header) → short-link rewrite → adapter send → record audit snapshot. **Why:** rewriting before render breaks Liquid; rewriting after send is too late (and requires knowledge of provider HTML mangling). **Trade-off:** short-link providers must accept multiple URLs per execution efficiently; we mitigate via per-execution caching keyed on (original, destination, provider, config-hash).

### D12. Audit snapshots include the rendered payload, redacted on the way in

We persist `step_executions.payload` and `step_executions.response` with secrets redacted by regex. **Why:** Operators want to debug "why did this user get this email?" weeks later. **Risk:** payload may contain personally-identifying data — mitigated by host-app retention configuration (set `retention_days` and a follow-on change ships the cleanup job).

### D13. Telemetry is the only programmatic observability surface

We do not log JSON or push to a specific APM. `:telemetry.execute/3` everywhere; the host attaches handlers (Phoenix.Telemetry, OpenTelemetry, etc). **Why:** keeps the library small and avoids forcing a logging philosophy. We document the event names and metadata maps in `DripDrop.Telemetry`.

### D14. `step_executions.state` enforced at the DB layer

A `CHECK` constraint plus a trigger validate the allowed state transitions described in `dispatch-execution`. **Why:** dispatch is the only writer in the happy path, but `unenroll/3` and admin tools also touch the table — encoding the FSM in SQL keeps every writer honest.

### D15. Encryption boundary: `credentials` and `auth_config` are encrypted; everything else is plaintext

We do NOT encrypt `payload` or `response` snapshots. **Why:** the redaction layer handles secret leakage; encrypting the whole snapshot would defeat the point of audit (operators couldn't read it without the key) and would slow queries that scan recent failures. **Risk:** if the redaction regex misses a pattern, plaintext leaks to the snapshot — mitigated by an allowlist of common secret keys plus an operator-extensible regex list.

### D16. Six channels ship in v1; eight email providers; OAuth is the host's problem

Channels: email, SMS, webhook, PubSub, Slack, Telegram. Each lives behind the `DripDrop.Channel` behavior. Adding a channel (e.g., WhatsApp) in a future change requires only a new module + tests.

Email providers shipped in v1: `mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`, `smtp`, `gmail`, `ms365`. The first six ride on top of `Swoosh` (existing or first-party adapters); `gmail` calls the Gmail API `users.messages.send` endpoint via `Req`; `ms365` calls the Microsoft Graph `/users/{user}/sendMail` endpoint via `Req`.

**OAuth posture for `gmail` and `ms365`:** DripDrop does **not** implement OAuth. The adapter's `credentials` map carries a `token_callback` MFA that the host implements (`Module.function(adapter) :: {:ok, %{access_token, expires_at}} | {:error, term()}`). The adapter calls the MFA before each send, caches the token until expiry in process state, and surfaces callback errors as the standard `:temporary | :permanent` taxonomy. **Why:** OAuth is large, host-specific, and intertwined with the host's identity layer (consent screens, refresh tokens, secret stores) — bringing it in-library would couple DripDrop to Google/Microsoft SDK choices and force every host to use our token store. The MFA-callback pattern keeps DripDrop entirely OAuth-ignorant. **Alternative considered:** ship our own refresh-token logic. Rejected — that's a meaningful subsystem we'd have to maintain and secure, and most hosts already have a working OAuth client. **Trade-off:** hosts with no existing OAuth setup need to build one.

**Recommended companion library (NOT a DripDrop dependency):** [Tango](https://github.com/agoodway/tango) is a sibling Elixir OAuth integration library (Phoenix-flavored, Nango-compatible, multi-tenant, AES-GCM-encrypted tokens, PKCE). A host that uses Tango can satisfy DripDrop's `token_callback` contract with a tiny adapter (`Tango.Connection.get_by_external_id/1` → return `{:ok, %{access_token, expires_at}}`). DripDrop guides will reference this as the canonical example, but Tango is **not** a hard, soft, or optional DripDrop dependency — it's listed only as a "if you don't already have OAuth, consider this" pointer. Other host OAuth choices (Ueberauth, Assent, custom) work equally well; the contract is just an MFA.

**First-class custom providers:** `DripDrop.Channels.register/3` lets a host plug in any module that implements the channel-provider contract (`deliver/3`, `validate_credentials/1`, `verify_signature/2`, `webhook_routes/1`). This means Resend, MailerSend variants, internal ESPs, or Postmark-compatible internal services all work without forking the library. **Why:** the README sets a "pluggable" expectation; the registration-by-MFA pattern is the smallest workable seam.

**Trade-off:** SMS and email each have meaningful provider differences that we hide behind one channel module — handled by per-provider sub-modules under `DripDrop.Channels.Email.<Provider>`. The per-provider files do the actual signature verification and event-shape decoding.

### D17. Dependency posture

Hard deps: `ecto`, `ecto_sql`, `postgrex`, `pgflow` (GitHub), `ecto_evolver` (GitHub), `crontab`, `cloak_ecto`, `req`, `jason`, `plug`, `floki` (HTML rewrite for short-links).
Optional deps (channels and conveniences): `swoosh` + `finch` (email), `solid` (Liquid templates), `mjml` (responsive email), `phoenix_pubsub` (in-app), `ex_aws_sns` (AWS SNS SMS).
Quality deps (dev/test only, `runtime: false`): `credo ~> 1.7`, `dialyxir ~> 1.4`, `sobelow ~> 0.14`, `doctor ~> 0.22`, `ex_dna ~> 1.2`. Wired into a `mix quality` alias borrowed from the goodsupport pattern: `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`.
Future-optional: `phoenix_live_view` (full editable dashboard in a follow-on change), `req_llm` + `zoi` (AI builder).

A capability fails compile (or boot) loudly when its optional dep is missing — see `DripDrop.startup_check/0` in tasks.md. **Why:** silent runtime failures (e.g., MJML compile error two weeks after deploy) are the worst kind. **Alternative:** make Swoosh/Solid hard deps. Rejected — host apps that don't use email shouldn't pull Swoosh's transitive surface.

### D18. Demo lives at `demo/`, mirrors the pgflow pattern, ships docker setup at the repo root

Structure: `demo/` is a sibling Phoenix 1.8 + LiveView 1.1 app with `{:dripdrop, path: ".."}`. The repo root carries a `Dockerfile` (Postgres 17 + pgmq v1.8.0 + pg_cron v1.6.4 baked in) and a `docker-compose.yml` exposing the `db` service. This deliberately copies pgflow's posture (see `/Users/chasepursley/Development/os/pgflow/Dockerfile`), so anyone coming from pgflow recognises the layout immediately. **Why one app instead of three:** a single demo means one Postgres image, one CI matrix, one set of seeds, and one place to wire the dispatch worker, ingest plug, and dashboard side-by-side. **Why a read-only dashboard inside the demo:** the editable dashboard is deferred to `add-dripdrop-dashboard`, but operators still need to see what's happening in their fixture data — read-only LiveViews give us 80% of the visibility for 5% of the surface area, and they can be migrated to the full dashboard later by promoting the views into a router macro. **Trade-off:** the demo can drift toward kitchen-sink. Mitigation — every scenario lives in its own `lib/dripdrop_demo_web/live/scenarios/<name>/` module with no shared business logic, and `mix demo.seed` is the only sanctioned way to load fixtures.

Mix tooling parallels pgflow's: DripDrop ships `mix dripdrop.setup` (with `--no-cron` to align with pgflow), `mix dripdrop.stamp` (adopt an existing `dripdrop` schema into evolver tracking), `mix dripdrop.check_schema`, `mix dripdrop.gen.key`, `mix dripdrop.rotate_key`, `mix dripdrop.uninstall`. We do NOT ship `dripdrop.gen.pgmq_migration` or `dripdrop.gen.postgres_extensions_migration` — those are pgflow's responsibility and DripDrop just runs after them.

## Risks / Trade-offs

- **Risk:** Cron-driven steps without pg_cron rely on the BEAM tick — if no node is running, those steps stall. → **Mitigation:** ship pg_cron as the recommended path; document `DripDrop.Jobs.CronTick` as a fallback; emit telemetry when the tick lags.
- **Risk:** Idempotency-key formula bakes `scheduled_for` truncated to minute — if a step is rescheduled by ≥1 minute (e.g., from quiet-hours deferral), the key changes and provider-side dedup is lost. → **Mitigation:** when policy reschedules, we track the *original* `scheduled_for` in `step_executions.metadata.original_scheduled_for` and use it for the idempotency key. Documented.
- **Risk:** Cold-outbound mode adds rules (per-mailbox cap, plain-text only, sender-domain isolation) that conflict with hosts that want to use the same library for both modes on the same domain. → **Mitigation:** modes are step-level, not adapter-level; the same adapter can serve both as long as the operator accepts the deliverability risk. The `cold.allow_primary_domain: true` escape hatch exists but emits a warning at boot.
- **Risk:** Floki-based HTML rewrite can mis-handle exotic markup (CDATA, conditional comments). → **Mitigation:** keep a documented allow-list of attributes (`href`, `src`) and bypass the rewrite for any URL inside `<style>`, `<script>`, or comments. Add property-based tests.
- **Risk:** Cloak encryption with a single key in env var — key compromise is a full DB compromise. → **Mitigation:** documented rotation task; suggest sealed secrets / SOPS in deployment docs; never log decrypted values.
- **Risk:** Tenant scoping is enforced in app code, not Postgres RLS. A bug in a query missing `tenant_key` could leak data. → **Mitigation:** every public API takes `tenant_key` explicitly; query helpers refuse to compile without a tenant clause when the called function is in the tenant-scoped set; add a property test that runs every public function and verifies no cross-tenant leakage.
- **Trade-off:** Telemetry-only observability means hosts pay the integration cost. We accept this in exchange for not opining on Sentry/Honeybadger/etc.

## Migration Plan

This is the initial release — there is no prior schema to migrate from. The host application steps are:

1. Add `:dripdrop` to `mix.exs` along with `:pgflow` and `:ecto_evolver`.
2. Run `mix pgflow.gen.postgres_extensions_migration` (with or without `--no-cron`), `mix pgflow.gen.pgmq_migration`, `mix pgflow.setup`.
3. Run `mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep`.
4. Run `mix dripdrop.setup` (creates the `dripdrop` schema and runs `V01`); accepts `--no-cron` to align with pgflow's posture and skip cron-tick wiring.
5. Run `mix ecto.migrate`.
6. Set `DRIPDROP_ENCRYPTION_KEY` (operator runs `mix dripdrop.gen.key` and stores the result in their secret manager).
7. Add a host-side PgFlow with `jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]`.
8. Mount webhook routes via `DripDrop.Web.Router.dripdrop_webhooks/1`.
9. Configure SPF/DKIM/DMARC for any sending domains; configure `unsubscribe_url_builder`.
10. Run `DripDrop.startup_check/0` in `Application.start/2` — fails fast on missing optional deps for configured channels, missing encryption key, missing PgFlow registration.

For local development of the library itself, the path is shorter: `docker compose up -d` from the repo root → `cd demo && mix setup && mix demo.seed && mix phx.server` → open `http://localhost:4000`.

**Rollback:** `DripDrop.uninstall/0` (in tasks) writes a script that drops the `dripdrop` schema and removes the PgFlow job rows. We do not auto-drop the schema — operators run the script knowing it's destructive.

## Open Questions

- **Q1.** Should the rate-limit token bucket use Postgres advisory locks (no extra dep) or Redis (better for high throughput)? Tentatively defaulting to Postgres with a Redis adapter behavior; revisit if a host hits ceiling.
- **Q2.** Should `enrollment.data` have a documented schema, or stay free-form? Free-form for v1; we may add per-sequence JSON Schema validation later.
- **Q3.** Where does the unsubscribe handler live — in the library (with a host-supplied signing secret) or in the host app? Tentatively: the library exposes `DripDrop.Web.UnsubscribePlug` that the host mounts, with the host providing `unsubscribe_secret`. Confirm with first integration partner.
- **Q4.** How do we treat `enrollments.data` updates after enrollment exists? Read-only after `enroll/1` for v1; merge-on-event in a follow-on change. Documented constraint.
- **Q5.** Do we want a `DripDrop.replay/1` for an operator to manually re-run a single execution? Tentatively yes (sets `attempt_window += 1` so a fresh idempotency key is computed), behind an admin-only function.
