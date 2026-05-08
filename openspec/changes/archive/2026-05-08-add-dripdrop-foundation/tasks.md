## 1. Project bootstrap

- [x] 1.1 Create `mix.exs` for `:dripdrop` (Elixir ~> 1.17, OTP ~> 26) with hard deps (`ecto`, `ecto_sql`, `postgrex`, `pgflow`, `ecto_evolver`, `crontab`, `cloak_ecto`, `req`, `jason`, `plug`, `floki`, `liquex`, `nebulex`, `nebulex_local`, `ex_phone_number`, `ex_email`, `standard_webhooks`), optional deps (`swoosh` + `finch`, `mjml`, `phoenix_pubsub`, `oban`, `ex_aws_sns`, `ex_gram`, `whatsapp_sdk`), and quality deps `only: [:dev, :test], runtime: false` (`credo ~> 1.7`, `ex_slop ~> 0.3`, `dialyxir ~> 1.4`, `sobelow ~> 0.14`, `doctor ~> 0.22`, `ex_dna ~> 1.2`).
- [x] 1.2 Configure library `mix.exs` `package:` files manifest to scope what would ship if the library is ever packaged (`lib`, `priv`, `config`, `guides`, `mix.exs`, `README.md`, `LICENSE`, etc.); set `preferred_envs: [precommit: :test, quality: :test]`.
- [x] 1.3 Define mix aliases: `precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`) and `quality` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`) — pattern lifted from `goodsupport/mix.exs`.
- [x] 1.4 Add `.credo.exs`, `.doctor.exs`, `.sobelow-conf`, `.formatter.exs`, `.dialyzer_ignore.exs`, `.tool-versions` at the repo root (mirror goodsupport defaults; tune to library shape).
- [x] 1.5 Add `lib/dripdrop/application.ex` with a Supervisor that boots `DripDrop.Vault`, the configured scheduler supervisor, and a Registry for short-link providers.
- [x] 1.6 Add `config/config.exs`, `config/dev.exs`, `config/test.exs` with sensible defaults (`scheduler: DripDrop.Schedulers.Pgflow`, `redaction_patterns: [...]`, `sms_max_chars: 1600`, `quiet_hours_default: {8, 21}`).
- [x] 1.7 Author `database/Dockerfile.postgres` mirroring goodsupport's layout: `FROM postgres:18-bookworm`, install `postgresql-18-cron` from PGDG apt, and wire `shared_preload_libraries` for pg_cron via `postgresql.conf` snippet. PG 18 supplies the native `uuidv7()` used as the default for every dripdrop table primary key. pgmq and pgflow are installed through generated PgFlow migrations, not baked into the image.
- [x] 1.8 Author `docker-compose.yml` at the repo root: single `db` service built from `./database` with `Dockerfile.postgres`, exposes a stable host port (`54325:5432` to avoid collision with GoodSupport/GoodJobs `54322`, PgFlow `54323`, and older DripDrop experiments), env vars `POSTGRES_DB=dripdrop_dev`, `POSTGRES_PASSWORD=postgres`, command sets `cron.database_name=dripdrop_dev`. PG 18's `/var/lib/postgresql` mount layout is used (the data dir lives in a major-version subdirectory inside the volume).
- [x] 1.9 Wire CI (GitHub Actions): matrix runs `mix quality`, `mix test` (with the Docker Postgres image as a service), `mix dialyzer`. Run a second matrix entry without pg_cron to verify the `--no-cron` fallback path stays green.
- [x] 1.10 Add `DripDrop.Telemetry` module documenting all event names (`[:dripdrop, :dispatch, ...]`, `[:dripdrop, :policy, ...]`, `[:dripdrop, :hook, ...]`, `[:dripdrop, :ingest, ...]`, `[:dripdrop, :template, ...]`, `[:dripdrop, :short_link, ...]`).
- [x] 1.11 Add `DripDrop.startup_check/0` that validates configured channels have their optional deps loaded, the encryption key decodes, the configured scheduler module exports the behavior callbacks, and PgFlow has registered `DripDrop.Jobs.DispatchStep` (warns when missing).

## 2. Schema and migrations (capability: cross-cutting)

- [x] 2.1 Add `DripDrop.Migration` using `EctoEvolver` with `default_prefix: "dripdrop"`, `tracking_object: {:view, "dripdrop_version"}`, `versions: [DripDrop.Migrations.V01]`.
- [x] 2.2 Write `DripDrop.Migrations.V01` raw SQL: create schema, create all 12 tables (`sequences`, `sequence_versions`, `steps`, `step_transitions`, `channel_adapters`, `conditions`, `http_hooks`, `enrollments`, `step_executions`, `events`, `suppressions`, `message_events`, `short_links`).
- [x] 2.3 Create unique constraints: `(tenant_key, key)` on sequences (with partial-NULL variant), `(sequence_id, version)`, partial unique on active version per sequence, `(sequence_version_id, key)` on steps, `(sequence_id, subscriber_type, subscriber_id)` on enrollments, `idempotency_key` on step_executions, `(channel, recipient)` on suppressions, `idempotency_key` on short_links, partial unique on `(provider, provider_event_id)` on message_events.
- [x] 2.4 Create CHECK constraints encoding the `step_executions.state` FSM (allowed transitions enforced via trigger fn `dripdrop.check_step_execution_state()`).
- [x] 2.5 Create indexes: `(state, scheduled_for)` on step_executions, `(sequence_id, state)` on enrollments, `(subscriber_type, subscriber_id, event_key, occurred_at)` on events, `(tenant_key)` on every tenant-scoped table.
- [x] 2.6 Add `mix dripdrop.setup` task following the `mix pgflow.setup` / `mix good_analytics.setup` pattern: generates ONE wrapper migration in the host app's `priv/<repo>/migrations/<timestamp>_setup_dripdrop.exs` whose `def up`/`def down` call `DripDrop.Migration.up/0` and `DripDrop.Migration.down/0`. Detects an existing setup migration (refuses to create duplicates). Accepts `--repo` and `--no-cron` flags. Does NOT fan out into pgflow's setup tasks — README documents the migration order.
- [x] 2.7 Add `mix dripdrop.gen.migration` task that generates a wrapper migration for incremental version updates (called by host on library upgrade), mirroring `mix good_analytics.gen.migration` and `mix pgflow.gen.helpers_migration`.
- [x] 2.9 Add `mix dripdrop.check_schema` task that verifies the current schema matches the latest version registered with `DripDrop.Migration` (mirrors `mix pgflow.check_schema`).
- [x] 2.11 Add `mix dripdrop.uninstall` task that emits a `DROP SCHEMA dripdrop CASCADE` script (does not run it; operator must confirm).
- [x] 2.12 Property test: every tenant-scoped query helper rejects calls without a `tenant_key` when one would be required (cross-tenant leakage guard).

## 3. Encryption (capability: cross-cutting)

- [x] 3.1 Implement `DripDrop.Vault` (Cloak vault) reading `DRIPDROP_ENCRYPTION_KEY` from env at boot.
- [x] 3.2 Implement `DripDrop.Encrypted.Map` (`use Cloak.Ecto.Map, vault: DripDrop.Vault`).
- [x] 3.3 Implement redaction helper `DripDrop.Redact.scrub/2` used everywhere snapshots are persisted (default regex list configurable via `config :dripdrop, redaction_patterns`). Key rotation is left to host applications via plain Elixir scripts (Cloak's standard rotation flow); DripDrop does not ship a built-in Mix task.

## 4. Sequence authoring (capability: sequence-authoring)

- [x] 4.1 Implement `DripDrop.Sequence` Ecto schema and changeset with `tenant_key`/`key` uniqueness logic.
- [x] 4.2 Implement `DripDrop.SequenceVersion` schema + activation changeset (`activate_sequence_version/1` runs both demote-and-promote in one `Ecto.Multi`).
- [x] 4.3 Implement `DripDrop.Step` schema with embedded `DripDrop.Timing` schema (immediate/delay/cron/event types) and validations from the spec.
- [x] 4.4 Implement `DripDrop.Timing.parse_human_friendly/1` for the documented expressions (`@daily`, `every monday at 9am`, `in 3 days`) and `DripDrop.Timing.calculate_next_run/2` for all four timing types.
- [x] 4.5 Implement `DripDrop.StepTransition` schema with `condition_mode: "always" | "all" | "any"` and priority ordering.
- [x] 4.6 Implement `DripDrop.Condition` schema with type-specific validation; reject `condition_type` values outside the registered set.
- [x] 4.7 Implement `DripDrop.SequenceAuthoring.validate_sequence_version/1` covering: entry path, adapter references, condition operands, cron expressions, hook references — exhaustive scenarios from the spec.
- [x] 4.8 Implement public API: `DripDrop.create_sequence/1`, `create_sequence_version/2`, `activate_sequence_version/1`, `create_step/2`, `create_step_transition/2`, `create_condition/2`.
- [x] 4.9 Tests: every authoring scenario in `specs/sequence-authoring/spec.md`, including duplicate-key-per-tenant, two-active-version rejection, fail-closed coercion telemetry assertion.

## 5. Hooks (capability: hooks)

- [x] 5.1 Define `DripDrop.HookBehavior` with `handle_hook/3`.
- [x] 5.2 Implement `DripDrop.HttpHook` schema with `auth_config` encrypted via `DripDrop.Encrypted.Map`, `timeout_ms` (default 5000, max 30000), `retry_count` (default 2, max 5).
- [x] 5.3 Implement `DripDrop.Hooks.Evaluator` that:
  - Resolves `:hook_function` against `sequence.hook_module` and invokes inside a `Task.async/1` guarded with `Task.yield/2 + Task.shutdown/1` so the timeout is hard.
  - Resolves `:http_hook_id` by fetching the row, rendering URL/body via the `templates` capability, calling `Req.request/1` with `:receive_timeout`, applying retry-with-backoff up to `retry_count`, and coercing the response to `response_type`.
  - Caches results per `step_execution_id` through `DripDrop.Cache` backed by Nebulex local cache.
- [x] 5.4 Implement `DripDrop.test_http_hook/2` that runs an evaluator pass outside any enrollment and stores `last_test_at` / `last_test_result` (with redaction).
- [x] 5.5 Public API: `DripDrop.create_http_hook/2`, `update_http_hook/2`, `test_http_hook/2`, `list_http_hooks/1`.
- [x] 5.6 Tests: every scenario in `specs/hooks/spec.md`, including hard timeout, hook-raise telemetry, caching across condition+template, coercion failure.

## 6. Templates (capability: templates)

- [x] 6.1 Implement `DripDrop.Templates.Renderer` with `render/3 :: (template, vars, channel) :: {:ok, payload} | {:error, reason}`.
- [x] 6.2 Implement Liquex (Liquid) backend with missing-variable warnings that emit the `[:dripdrop, :template, :missing_variable]` event while rendering missing values as empty.
- [x] 6.3 Implement EEx backend (module-only) used when `step.template_type == "module"`.
- [x] 6.4 Implement MJML compile step gated on `step.config["body_format"] == "mjml"` or detection of leading `<mjml>` tag; map errors to `{:error, %{kind: :permanent, reason: {:mjml_compile, _}}}`.
- [x] 6.5 Implement `DripDrop.Templates.Variables` resolver merging step config → hook results → enrollment data → system variables (override order from spec).
- [x] 6.6 Per-channel payload validators (email, sms, webhook, pubsub, slack, telegram) producing the documented payload shape and validating sms-too-long / empty-body / chat-id presence.
- [x] 6.7 Implement `DripDrop.Templates.validate/2` for authoring-time syntax validation; wire into `validate_sequence_version/1`.
- [x] 6.8 Tests: every scenario in `specs/templates/spec.md`, plus property test that arbitrary Liquid input never raises (only returns `{:error, ...}` or empty-string-substitutions).

## 7. Channel adapters (capability: channel-adapters)

- [x] 7.1 Implement `DripDrop.ChannelAdapter` schema with `credentials` and `config` types, `validate_credentials` callback hook into the channel's module.
- [x] 7.2 Implement `(channel, tenant_key)` partial-unique-default constraint via a deferred trigger that flips defaults atomically.
- [x] 7.3 Define `DripDrop.Channel` behavior with `deliver/3`, `validate_credentials/1`, `webhook_routes/1`, `verify_signature/2`.
- [x] 7.4 Implement `DripDrop.Channels.Email` plus per-provider sub-modules using Swoosh where adapters exist (`Mailgun`, `SendGrid`, `Postmark`, `MailerSend`, `SES`, `SMTP`); map provider errors to `:temporary | :permanent` taxonomy. Each sub-module exposes `validate_credentials/1`, `deliver/3`, `verify_signature/2` (when the provider has webhooks), `webhook_routes/1`.
- [x] 7.4a Implement `DripDrop.Channels.Email.Gmail` (Google Gmail API, `users.messages.send`): call `token_callback` MFA before send, cache token until `expires_at`, build base64-url-encoded RFC 5322 message, surface `{:error, %{kind: :permanent, reason: {:token_callback, :revoked}}}` on auth failures. **OAuth flows are explicitly out of scope** — host owns the callback.
- [x] 7.4b Implement `DripDrop.Channels.Email.Ms365` (Microsoft Graph `/users/{user}/sendMail`): same token-callback pattern as Gmail, build Graph JSON payload shape (`message: %{subject, body: %{contentType, content}, toRecipients: [...], ...}`).
- [x] 7.4c Implement `DripDrop.Channels.register/3` for host-registered custom providers (e.g., Resend, MailerSend variants, internal providers). Registration registers in a `:persistent_term` keyed by `{channel, provider}`; `channel_adapters` changeset consults the registry alongside built-ins.
- [x] 7.4d Property test: token-callback adapters cache tokens until `expires_at`, refresh on the next send after expiry, and never call the callback more than once per send when `expires_at` is in the future.
- [x] 7.5 Implement `DripDrop.Channels.SMS` with `Twilio` and `AwsSns` providers; pass `Idempotency-Key` to Twilio.
- [x] 7.6 Implement `DripDrop.Channels.Webhook` (no provider distinction; renders URL/method/body/headers via `templates`).
- [x] 7.7 Implement `DripDrop.Channels.PubSub` (uses `Phoenix.PubSub` from host).
- [x] 7.8 Implement `DripDrop.Channels.Slack` (`webhook` provider).
- [x] 7.9 Implement `DripDrop.Channels.Telegram` (`bot_api` provider).
- [x] 7.10 Implement `DripDrop.ChannelAdapters.select/3` covering the step → sequence → tenant default → global default chain plus weighted rotation with sticky-retry semantics.
- [x] 7.11 Public API: `DripDrop.create_channel_adapter/1`, `update_channel_adapter/2`, `list_channel_adapters/1`, `get_default_adapter/2`.
- [x] 7.12 Tests: every scenario in `specs/channel-adapters/spec.md`, plus a contract test that every shipping channel implements all behavior callbacks and round-trips a fixture payload.

## 8. Short links (capability: short-links)

- [x] 8.1 Define `DripDrop.ShortLinks.Adapter` behavior, `Request` and `Result` structs.
- [x] 8.2 Implement `DripDrop.ShortLinks.Pipeline` with steps: extract → eligibility filter → enrich (UTM) → resolve via adapter (with idempotency cache lookup) → rewrite → persist `short_links` row.
- [x] 8.3 Implement HTML rewriter using Floki, only `href`/`src` attributes, skipping `<style>`/`<script>`/comments.
- [x] 8.4 Implement plain-text rewriter that handles trailing punctuation safely (test: `Visit https://example.com.` rewrites with the period preserved).
- [x] 8.6 Implement `DripDrop.ShortLinks.GoodAnalytics` adapter (in-process call to `GoodAnalytics.create_link/1`); fall back to instructive error when `:good_analytics` is not loaded.
- [x] 8.7 Implement `DripDrop.ShortLinks.Module`, `DripDrop.ShortLinks.Webhook`, `DripDrop.ShortLinks.None`.
- [x] 8.8 Implement config cascade resolver (global → tenant → sequence → step) and exclusion-pattern merging.
- [x] 8.9 Implement `on_error: :send_originals` fallback path, recording flag in `step_executions.response.short_links_fallback`.
- [x] 8.10 Tests: every scenario in `specs/short-links/spec.md`, plus property test that extracted-then-rewritten HTML preserves byte-equality outside `href`/`src`.

## 9. Messaging policy (capability: messaging-policy)

- [x] 9.1 Implement `DripDrop.Suppressions` with normalize-and-upsert semantics keyed on `(channel, recipient_normalized)`; per-channel normalizers (`email`/`sms`/`webhook`/`slack`/`telegram`).
- [x] 9.2 Implement `DripDrop.Policy.Gate` that runs as the FIRST in-dispatch policy step, checking suppression before rendering.
- [x] 9.3 Implement opt-in RFC 8058 header injection in `DripDrop.Policy.UnsubscribeHeaders` invoked between render and adapter send for email steps with `unsubscribe_headers`/`unsubscribe` enabled; refuse to start if `unsubscribe_url_builder` is unconfigured AND any sequence has opted-in email steps.
- [x] 9.4 Implement `DripDrop.Policy.QuietHours` with recipient timezone resolution (`enrollment.data["timezone"]` → channel-specific fallback → tenant default), TCPA SMS default 8 AM–9 PM, deferral via re-scheduling.
- [x] 9.5 Implement `DripDrop.Policy.RateLimit` token-bucket (Postgres advisory locks default; Redis adapter behavior for opt-in) at four scopes simultaneously; emit telemetry on hits; defer (do not fail) on hit.
- [x] 9.6 Implement `DripDrop.Policy.BounceComplaintThresholds` running asynchronously (every minute) over rolling 30-day window per adapter; emit `complaint_threshold` / `bounce_threshold` events and set `channel_adapters.config["paused_until"]` when exceeded.
- [x] 9.7 Implement explicit sending rules for daily-cap deferral and optional `recipient_verified_at` requirement without operating modes.
- [x] 9.8 Implement audit-snapshot redaction in `DripDrop.Redact.scrub/2` (called on payload + response before insert).
- [x] 9.9 Tests: every scenario in `specs/messaging-policy/spec.md`, including 0.3% complaint threshold, 2% bounce threshold, TCPA quiet hours timezone shift, and sender-mailbox daily cap.

## 9a. Foundation enforcement patches (cold-mode prerequisites)

These tasks close gaps discovered while planning `add-cold-outbound-mode`: the paused-adapter signal that `BounceComplaintThresholds` already writes is currently never read by dispatch (a half-wired safety control), and the rate-limit scopes need a `recipient_domain` bucket to protect against intra-domain volume spikes. Folded into foundation because they are correctness fixes to behavior already in scope, not new outbound capability.

- [x] 9a.1 Wire `adapter.config["paused_until"]` enforcement into the dispatch path. Add a check in `DripDrop.Jobs.DispatchStep` (or a small `DripDrop.Policy.AdapterPause` module that runs after `ChannelAdapters.select/3` and before `Concurrency.check/2`) that reads the resolved adapter's `config["paused_until"]`, parses it via `DateTime.from_iso8601/1`, and when the parsed timestamp is in the future returns `{:defer, paused_until, %{reason: "adapter_paused", paused_reason: adapter.config["paused_reason"]}}`. The existing `defer/3` path in `DispatchStep` already handles the rest (re-schedule, emit `deferred` message_event). Emit `[:dripdrop, :policy, :adapter_paused]` telemetry with `adapter_id`, `paused_reason`, `paused_until`, `step_execution_id`, `tenant_key`. Stale or unparseable `paused_until` values are treated as "not paused" (logged via telemetry but do not block sends).
- [x] 9a.2 Add `recipient_domain` as the fifth scope in `DripDrop.Policy.RateLimit`. Append `:recipient_domain` to `@scopes`. Implement `scope_key(:recipient_domain, target)` extracting the domain part of `target.recipient` for the email channel; for non-email channels (sms, slack, telegram, webhook, pubsub) skip the scope (return `:skip`) since "recipient domain" is email-specific. Surface configuration through the existing `rate_limits` map: `%{recipient_domain: %{limit: 10, window_seconds: 60}}` resolved through the same global → adapter → step deep-merge cascade.
- [x] 9a.3 Update `DripDrop.Helpers` (or wherever `email_domain/1` lives) to expose a `recipient_domain/1` helper that mirrors the sending-domain extraction logic but operates on `to`/`recipient` rather than `from`/`reply_to`. Reuse where possible.
- [x] 9a.4 Tests for paused-adapter enforcement: (a) adapter with `paused_until` 1 hour in the future blocks dispatch and re-schedules to that exact timestamp, (b) adapter with `paused_until` in the past dispatches normally, (c) adapter with malformed `paused_until` string dispatches normally and emits a parse-warning telemetry event, (d) `[:dripdrop, :policy, :adapter_paused]` telemetry fires with the documented metadata.
- [x] 9a.5 Tests for recipient-domain rate limit: (a) eleventh send to `gmail.com` within a 10/minute bucket defers correctly, (b) the same eleventh send is NOT counted twice against the per-recipient bucket, (c) non-email channels skip the scope, (d) the scope is configurable via app, adapter, and step config with deep-merge precedence.
- [x] 9a.6 Tests for the rotation-independence clarification scenario in `specs/channel-adapters/spec.md`: an enrollment with two steps configured for `[mailgun:50, sendgrid:50]` rotation observes that the two step executions select adapters independently (verified by inspecting `step_executions.metadata->>'adapter_id'` after both dispatch — across many trials, not strictly equal nor strictly different). Just confirms that the per-execution selection is non-pinned by design.

## 10. Dispatch execution (capability: dispatch-execution)

- [x] 10.1 Define `DripDrop.Scheduler` behavior; implement `DripDrop.Schedulers.Pgflow` (calls `PgFlow.enqueue/2`) and `DripDrop.Schedulers.Oban` (queue: `:dripdrop`).
- [x] 10.2 Implement `DripDrop.Jobs.DispatchStep` with `perform/1` that:
  1. Claims the row via `UPDATE ... WHERE id = $1 AND state = 'scheduled' RETURNING *`.
  2. Loads enrollment + step + adapter context.
  3. Calls `DripDrop.Policy.Gate.check/1`; on `:skip`, transitions `→ skipped`, schedules next.
  4. Calls `DripDrop.Hooks.Evaluator.resolve/2` and caches results.
  5. Calls `DripDrop.Templates.Renderer.render/3`.
  6. Calls `DripDrop.Policy.UnsubscribeHeaders.apply/2` (email opt-in only).
  7. Calls `DripDrop.ShortLinks.Pipeline.run/2`.
  8. Calls `DripDrop.Channel.deliver/3`.
  9. Persists `payload` (redacted), `response` (redacted), `provider_message_id`; transitions `→ sent` or `→ failed`.
  10. Resolves `step_transitions` and schedules next step or completes enrollment.
- [x] 10.3 Compute idempotency keys via documented formula; pass through to providers that support `Idempotency-Key`.
- [x] 10.4 Implement `DripDrop.Jobs.CronTick` (PgFlow job) that runs every minute when pg_cron is unavailable.
- [x] 10.5 Implement `DripDrop.Dispatch.Concurrency` allowing per-channel and per-adapter concurrency caps via configured worker pools.
- [x] 10.6 Implement DB-level state-machine trigger function `dripdrop.check_step_execution_state()` rejecting illegal transitions.
- [x] 10.7 Implement `DripDrop.Dispatch.replay/1` that bumps `attempt_window` to force a fresh idempotency key for an admin-initiated retry.
- [x] 10.8 Tests: every scenario in `specs/dispatch-execution/spec.md`, plus a chaos test that kills the worker mid-send (after provider call, before commit) and asserts no duplicate provider message.

## 11. Enrollment lifecycle (capability: enrollment-lifecycle)

- [x] 11.1 Implement `DripDrop.Enrollment` schema with state machine constants and explicit transitions.
- [x] 11.2 Implement `DripDrop.enroll/1` as a single `Ecto.Multi`: insert enrollment + insert first `step_executions` row + scheduler enqueue.
- [x] 11.3 Implement `DripDrop.unenroll/3`, `pause_enrollment/1`, `resume_enrollment/1` — paused enrollments cancel pending `step_executions` and re-schedule on resume.
- [x] 11.4 Implement `DripDrop.track_event/3` accepting either `enrollment_id` or `%{subscriber_type, subscriber_id}` map.
- [x] 11.5 Implement event-trigger dispatch: when an event matches a step with `timing.type = "event"`, schedule that step within the next worker tick.
- [x] 11.6 Implement `DripDrop.list_active_enrollments/1`, `get_enrollment/3` query helpers.
- [x] 11.7 Tests: every scenario in `specs/enrollment-lifecycle/spec.md`, including the re-enrollment idempotency case and tenant-mismatch rejection.

## 12. Event ingestion (capability: event-ingestion)

- [x] 12.1 Implement `DripDrop.Web.WebhookPlug` (Plug-based, framework-agnostic) that dispatches to per-provider handlers based on path segments.
- [x] 12.2 Implement `DripDrop.Web.Router.dripdrop_webhooks/1` macro that mounts a base path inside Phoenix Router with the plug.
- [x] 12.3 Implement signature verification per webhook-pushing provider: Mailgun (HMAC-SHA256 of timestamp+token), SendGrid (ECDSA over timestamp+raw body), Postmark (basic auth), MailerSend (HMAC-SHA256 with `Signature` header), Twilio (HMAC-SHA1 of URL+sorted params), SES (SNS-verified). Document explicitly that `gmail`, `ms365`, `smtp`, `pubsub`, `slack`, and `telegram` do NOT register webhook ingest routes for delivery events — for those providers the `sent` state is the terminal positive signal.
- [x] 12.4 Implement event normalization into `message_events` rows; map provider events to the canonical `event_type` enum.
- [x] 12.5 Implement `(provider, provider_event_id)` deduplication via partial unique index; convert violation to `200` with telemetry event.
- [x] 12.6 Implement bounce/complaint/unsubscribe → suppression upsert in single `Ecto.Multi` transaction.
- [x] 12.7 Implement reply detection routing via configured `DripDrop.OnReply` callback (default: pause enrollment only when `reply_behavior: "pause_enrollment"` is set).
- [x] 12.8 Tests: every scenario in `specs/event-ingestion/spec.md`, including invalid signature, unmatched event id, soft-vs-hard bounce, reply detection, duplicate event 200 no-op.

## 13. Public API surface and documentation

- [x] 13.1 Implement top-level `DripDrop` module re-exporting the documented public API (sequences, versions, steps, conditions, adapters, hooks, enrollments, events, replay).
- [x] 13.2 Add `@doc` and `@spec` for every public function, including a worked example.
- [x] 13.3 Document `DripDrop.Telemetry` event names, metadata maps, and recommended Phoenix.Telemetry attachments.
- [x] 13.4 Author `guides/installation.md`, `guides/sending_rules.md`, `guides/lifecycle_email.md`, `guides/quiet_hours.md`, `guides/short_links.md`, `guides/operations.md`.
- [x] 13.5 Author `guides/extending.md`: how to write a custom channel adapter, custom short-link adapter, custom scheduler, custom hook module. Include a dedicated **"Adding a new email provider"** section walking through the four-step recipe (Swoosh adapter or direct API → `validate_credentials/1` → signature verifier if applicable → `DripDrop.Channels.register/3`).
- [x] 13.5a Author `guides/oauth_providers.md` covering the `token_callback` contract for Gmail and MS365: what the MFA must return, how token caching works, error taxonomy. Show three worked examples — (a) hand-rolled with `Req` and a refresh token in env, (b) using [Tango](https://github.com/agoodway/tango) (recommended companion library — explicitly NOT a DripDrop dependency; ~10 lines: `Tango.Connection.get_by_external_id/1` adapter), (c) using Ueberauth + a host-owned refresh job. State plainly that DripDrop never reads OAuth client secrets, never persists refresh tokens, and never makes refresh requests.
- [x] 13.6 Generate ExDoc HTML into `doc/` via `mix docs`. Verify the documented public API (`DripDrop.*` functions, behaviors, telemetry events) renders without warnings.

## 14. Demo application

The Phoenix demo application is no longer part of foundation. It has been extracted into `add-dripdrop-demo-app` to unblock the library's `v0.1.0` archive. The demo capability previously declared in this change has been removed from `proposal.md`, `design.md` (D18 was rewritten to focus on the repo-root Docker assets that remain in foundation), and `specs/`. Foundation tasks 1.7 and 1.8 (which authored the `Dockerfile` and `docker-compose.yml` at the repo root) remain — those are library infrastructure, not demo work, and the demo simply uses them.

## 14a. Cross-cutting integration tests

The unit tests pass against `DripDrop.Schedulers.Test` (in-memory, synchronous). These integration tests exercise the **real** PgFlow scheduler against the Docker Postgres image, which is the path that production uses. They are tagged `@moduletag :integration` and excluded from the default `mix test` run; CI invokes them via `mix test --only integration` as a separate matrix entry.

### 14a.0. Prerequisites

These foundational pieces unblock all three integration tests. Land them first.

- [x] 14a.0.1 Generate the PgFlow job migration for `DripDrop.Jobs.DispatchStep` into `test/support/priv/repo/migrations/` (run `mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep` and place the output before the `setup_dripdrop` migration in timestamp order). Without this migration the PgFlow `enqueue/2` call fails because the job's queue table doesn't exist. Verify the migration runs cleanly via `mix ecto.reset`.
- [x] 14a.0.2 Spike — confirm whether `DripDrop.Channels.Telegram` (uses `ex_gram` SDK) and `DripDrop.Channels.SMS.Twilio` honor `adapter.config["channel_req_options"]` end-to-end. If either bypasses `Req`, those providers' integration tests in 14a.2 must use Bypass instead of `Req.Test`. Document findings in a comment in `test/integration/providers/README.md`.
- [x] 14a.0.3 Implement `DripDrop.IntegrationCase` at `test/support/integration_case.ex`. Like `DataCase` but with `async: false` baked in, NO Ecto sandbox, and a `setup_all`/`on_exit` cleanup that TRUNCATEs `dripdrop.*` tables (`step_executions`, `enrollments`, `events`, `message_events`, `suppressions`, `short_links`, `channel_adapters`, `sequences`, `sequence_versions`, `steps`, `step_transitions`, `conditions`, `http_hooks`) AND PgFlow runtime tables (`pgflow.flow_runs`, `pgflow.step_tasks`, `pgflow.step_states`, `pgflow.deps` — confirm exact list against `setup_pgflow.exs` output). Expose `eventually/2 :: ((-> term()), keyword()) :: term()` polling helper that retries an assertion until success or timeout (default 5s, ~50ms tick).
- [x] 14a.0.4 Implement `DripDrop.TestSupport.PgflowHarness` at `test/support/pgflow_harness.ex`. Module exposes `child_spec/1` for `start_supervised!/1` use; boots one PgFlow worker for `DripDrop.Jobs.DispatchStep` with `min_poll_interval: 50`, `max_poll_interval: 100` (vs. production defaults of ~1s). Also exposes `wait_for_idle/1 :: (timeout_ms) :: :ok | :timeout` that blocks until the queue has no pending or in-flight tasks for `DripDrop.Jobs.DispatchStep`.
- [x] 14a.0.5 Implement `DripDrop.TestSupport.Integration.Scenarios` at `test/support/integration/scenarios.ex`. Composes existing `DripDrop.Fixtures.*` primitives into reusable scenario builders: at minimum `email_full_scenario/1` returning `%{sequence, version, step, enrollment, adapter}` for the standard "enroll a user, send email, ingest webhook" flow. Avoid opaque blob fixtures; each builder is small and obvious.
- [x] 14a.0.6 Tag integration test files with `@moduletag :integration`. Update `test/test_helper.exs` to exclude `:integration` from default runs: `ExUnit.configure(exclude: [:integration])`. Document in `README.md` how to run them: `mix test --only integration`.

### 14a.1. Full-stack integration test

- [x] 14a.1.1 Implement `test/integration/full_stack_test.exs` happy-path test: build `Scenarios.email_full_scenario/1` with two email steps; stub Mailgun outbound via `Req.Test`; `DripDrop.enroll/1`; `PgflowHarness.wait_for_idle()`; assert step 1 `step_execution.state == "sent"` and a `message_events` row of type `"sent"` exists; build a Mailgun delivery webhook payload via existing `webhook_fixtures`; POST it through `DripDrop.Web.WebhookPlug`; assert `message_events` row of type `"delivered"` and step 2 is scheduled.
- [x] 14a.1.2 Add suppression-on-bounce variant to the same file: simulate a Mailgun hard bounce webhook for step 1's recipient; assert a `suppressions` row is upserted with `reason: "bounce"` and `recipient_normalized` matches; assert step 2's eventual dispatch transitions `claiming → skipped` because the recipient is now suppressed.
- [x] 14a.1.3 Add pre-suppressed-recipient variant: insert a `suppressions` row before enrolling; assert dispatch immediately transitions `claiming → skipped` and emits the documented telemetry; assert no provider HTTP call was made (verified via `Req.Test` strict-stub behavior).
- [x] 14a.1.4 Add HTTP-hook variant: extend `Scenarios` with a sequence whose step has a Liquex template referencing an `http_hook` result; stub the hook endpoint via `Req.Test` to return a deterministic JSON body; assert the rendered email body contains the hook-derived value. Validates the hooks → templates → adapter chain end-to-end.
- [x] 14a.1.5 Add `setup_all` env management: snapshot `:scheduler`, `:dispatch_stale_after_seconds`, and any other test-specific overrides; restore on `on_exit`. Set `:scheduler` to `DripDrop.Schedulers.Pgflow` and `:dispatch_stale_after_seconds` to 5 for the module.

### 14a.2. Provider-stub integration tests

Each test file in `test/integration/providers/` exercises one channel module's outbound delivery shape AND inbound webhook signature verification. These tests do NOT need PgFlow — they call `Channel.deliver/3` and `WebhookPlug.call/2` directly, using `DripDrop.DataCase` (sandbox is fine here) for isolation. Use `Req.Test` where the channel honors `:channel_req_options` (default), Bypass where 14a.0.2 found a gap.

- [x] 14a.2.1 `test/integration/providers/mailgun_test.exs` — outbound: assert POST to `/v3/<domain>/messages`, Basic auth header present, body has `from`/`to`/`subject`/`text`. Inbound: build a signed Mailgun event via `webhook_fixtures`, assert valid HMAC-SHA256(timestamp+token) is accepted and a tampered signature is rejected with `:invalid_signature`.
- [x] 14a.2.2 `test/integration/providers/sendgrid_test.exs` — outbound: assert POST to `https://api.sendgrid.com/v3/mail/send`, `Authorization: Bearer <key>`, payload shape per SendGrid v3 schema. Inbound: build a SendGrid event with valid ECDSA signature over `(timestamp + raw body)`, assert acceptance; tampered signature rejected.
- [x] 14a.2.3 `test/integration/providers/twilio_test.exs` — outbound: assert POST to `/2010-04-01/Accounts/<sid>/Messages.json`, Basic auth, form-encoded body with `To`/`From`/`Body`. Inbound: build a Twilio status callback with valid HMAC-SHA1 of `URL + sorted-params`; tampered signature rejected. Note: depends on 14a.0.2 finding for whether `Req.Test` or Bypass is used.
- [x] 14a.2.4 `test/integration/providers/slack_test.exs` — outbound only (Slack incoming-webhook has no signed inbound events): assert POST to the configured incoming-webhook URL, JSON body shape `%{text: ..., blocks?: ...}`. Verify `webhook_routes/1` returns `[]` for the Slack adapter (no inbound routes registered).
- [x] 14a.2.5 `test/integration/providers/telegram_test.exs` — outbound only (bot API has no inbound to DripDrop): assert POST to `api.telegram.org/bot<token>/sendMessage`, body has `chat_id` and `text`. Note: depends on 14a.0.2 finding for `ex_gram` SDK vs `Req`.
- [x] 14a.2.6 Add a brief `test/integration/providers/README.md` documenting the per-provider scope (outbound shape, inbound signature where applicable), the Req.Test-vs-Bypass decision per provider (from 14a.0.2), and how to add a new provider's integration test.

### 14a.3. Chaos integration test

- [x] 14a.3.1 Implement `test/support/channels/crash_email.ex` — a test-only email channel implementing the `DripDrop.Channel` behaviour. Configurable via `adapter.config["crash_mode"]` to one of `none | after_success | before_success`; in `after_success` mode it returns `{:ok, %{provider_message_id: "msg-#{counter}"}}` then `Process.exit(self(), :kill)` before the calling process can persist. Tracks call counts via a named test agent so retries are detectable. Registers itself via `DripDrop.Channels.register/3` in the test's `setup_all`.
- [x] 14a.3.2 Implement `test/integration/chaos_test.exs` — boot `PgflowHarness`, set `:dispatch_stale_after_seconds` to 2 (CRITICAL: default 900 is too long for the test runtime), register the crash adapter, build an email scenario using it; enroll; observe first claim → provider success → worker crash; wait for stale recovery to fire; assert exactly 2 calls to the crash adapter, exactly 1 `step_execution` row in state `"sent"`, exactly 1 `message_events` row of type `"sent"`, and the persisted `provider_message_id` matches the second-call return value (the retry's response is what got committed).
- [x] 14a.3.3 Add idempotency-key parity check to chaos test: assert the `step_executions.idempotency_key` value did not change between the crashed attempt and the recovered attempt — same `(enrollment_id, step_id, scheduled_for, attempt_window)` tuple, same digest, which is what makes the duplicate-suppression invariant hold at the provider level too.

### 14a.4. CI integration

- [x] 14a.4.1 Add a new GitHub Actions matrix entry to `.github/workflows/ci.yml` that runs `mix test --only integration` after the main `mix test` pass succeeds. Reuses the same Docker Postgres service container as the main matrix entry. Marked non-blocking initially (so test flake doesn't gate library development) until two consecutive green CI runs are observed; then promote to required.
- [x] 14a.4.2 Document the integration test workflow in `guides/operations.md` (or a new `guides/contributing.md`): how to run integration tests locally (`docker compose up -d && mix test --only integration`), how to add a new integration test (use `DripDrop.IntegrationCase`, tag `@moduletag :integration`, register cleanup via the case template), and how to debug PgFlow timing flakes (lower polling intervals, longer `eventually/2` timeouts, log inspection).

## 15. Validation and release

- [x] 15.1 Run `openspec validate add-dripdrop-foundation` — must pass.
- [x] 15.2 Run `mix quality` at repo root — must pass (warnings-as-errors, format check, sobelow, ex_dna, doctor, credo strict). The demo's own `mix quality` alias is owned by `add-dripdrop-demo-app` and is not invoked from foundation CI.
- [x] 15.3 Run full test suite under Postgres 18 with pgmq + pg_cron via the Docker image.
- [x] 15.4 Run full test suite under Postgres 18 WITHOUT pg_cron (verify `CronTick` fallback) — second CI matrix entry.
- [x] 15.5 Run dialyzer with no warnings.
- [x] 15.7 Update top-level `README.md` with installation quickstart that points at `guides/installation.md`. (The link to `demo/README.md` is added by `add-dripdrop-demo-app` task 6.4 once the demo ships.)

> **Note:** Manual deliverability smoke (formerly task 15.6) is owned by `add-dripdrop-demo-app` since it requires the demo. Foundation's release validation is satisfied by 15.1–15.5 plus the integration tests in 14a.
