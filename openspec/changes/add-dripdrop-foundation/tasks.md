## 1. Project bootstrap

- [ ] 1.1 Create `mix.exs` for `:dripdrop` (Elixir ~> 1.17, OTP ~> 26) with hard deps (`ecto`, `ecto_sql`, `postgrex`, `pgflow`, `ecto_evolver`, `crontab`, `cloak_ecto`, `req`, `jason`, `plug`, `floki`), optional deps (`swoosh` + `finch`, `solid`, `mjml`, `phoenix_pubsub`, `ex_aws_sns`), and quality deps `only: [:dev, :test], runtime: false` (`credo ~> 1.7`, `dialyxir ~> 1.4`, `sobelow ~> 0.14`, `doctor ~> 0.22`, `ex_dna ~> 1.2`).
- [ ] 1.2 Configure library `mix.exs` `package:` to exclude `demo/` from Hex publishing; set `preferred_envs: [precommit: :test, quality: :test]`.
- [ ] 1.3 Define mix aliases: `precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`) and `quality` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`) — pattern lifted from `goodsupport/mix.exs`.
- [ ] 1.4 Add `.credo.exs`, `.doctor.exs`, `.sobelow-conf`, `.formatter.exs`, `.dialyzer_ignore.exs`, `.tool-versions` at the repo root (mirror goodsupport defaults; tune to library shape).
- [ ] 1.5 Add `lib/dripdrop/application.ex` with a Supervisor that boots `DripDrop.Vault`, the configured scheduler supervisor, and a Registry for short-link providers.
- [ ] 1.6 Add `config/config.exs`, `config/dev.exs`, `config/test.exs` with sensible defaults (`scheduler: DripDrop.Schedulers.Pgflow`, `redaction_patterns: [...]`, `sms_max_chars: 1600`, `quiet_hours_default: {8, 21}`).
- [ ] 1.7 Author `Dockerfile` at the repo root: `FROM postgres:17`, build pgmq v1.8.0 and pg_cron v1.6.4 from source (mirror `pgflow/Dockerfile`), wire `shared_preload_libraries` for pg_cron via `postgresql.conf` snippet.
- [ ] 1.8 Author `docker-compose.yml` at the repo root: single `db` service built from `./Dockerfile`, exposes a stable host port (e.g., `54324:5432` to avoid collision with pgflow's `54322`/`54323`), env vars `POSTGRES_DB=dripdrop_dev`, `POSTGRES_PASSWORD=postgres`, command sets `cron.database_name=dripdrop_dev`.
- [ ] 1.9 Wire CI (GitHub Actions): matrix runs `mix quality`, `mix test` (with the Docker Postgres image as a service), `mix dialyzer`. Run a second matrix entry without pg_cron to verify the `--no-cron` fallback path stays green.
- [ ] 1.10 Add `DripDrop.Telemetry` module documenting all event names (`[:dripdrop, :dispatch, ...]`, `[:dripdrop, :policy, ...]`, `[:dripdrop, :hook, ...]`, `[:dripdrop, :ingest, ...]`, `[:dripdrop, :template, ...]`, `[:dripdrop, :short_link, ...]`).
- [ ] 1.11 Add `DripDrop.startup_check/0` that validates configured channels have their optional deps loaded, the encryption key decodes, the configured scheduler module exports the behavior callbacks, and PgFlow has registered `DripDrop.Jobs.DispatchStep` (warns when missing).

## 2. Schema and migrations (capability: cross-cutting)

- [ ] 2.1 Add `DripDrop.Migration` using `EctoEvolver` with `default_prefix: "dripdrop"`, `tracking_object: {:view, "dripdrop_version"}`, `versions: [DripDrop.Migrations.V01]`.
- [ ] 2.2 Write `DripDrop.Migrations.V01` raw SQL: create schema, create all 12 tables (`sequences`, `sequence_versions`, `steps`, `step_transitions`, `channel_adapters`, `conditions`, `http_hooks`, `enrollments`, `step_executions`, `events`, `suppressions`, `message_events`, `short_links`).
- [ ] 2.3 Create unique constraints: `(tenant_key, key)` on sequences (with partial-NULL variant), `(sequence_id, version)`, partial unique on active version per sequence, `(sequence_version_id, key)` on steps, `(sequence_id, subscriber_type, subscriber_id)` on enrollments, `idempotency_key` on step_executions, `(channel, recipient)` on suppressions, `idempotency_key` on short_links, partial unique on `(provider, provider_event_id)` on message_events.
- [ ] 2.4 Create CHECK constraints encoding the `step_executions.state` FSM (allowed transitions enforced via trigger fn `dripdrop.check_step_execution_state()`).
- [ ] 2.5 Create indexes: `(state, scheduled_for)` on step_executions, `(sequence_id, state)` on enrollments, `(subscriber_type, subscriber_id, event_key, occurred_at)` on events, `(tenant_key)` on every tenant-scoped table.
- [ ] 2.6 Add `mix dripdrop.setup` task following the `mix pgflow.setup` / `mix good_analytics.setup` pattern: generates ONE wrapper migration in the host app's `priv/<repo>/migrations/<timestamp>_setup_dripdrop.exs` whose `def up`/`def down` call `DripDrop.Migration.up/0` and `DripDrop.Migration.down/0`. Detects an existing setup migration (refuses to create duplicates). Accepts `--repo` and `--no-cron` flags. Does NOT fan out into pgflow's setup tasks — README documents the migration order.
- [ ] 2.7 Add `mix dripdrop.gen.migration` task that generates a wrapper migration for incremental version updates (called by host on library upgrade), mirroring `mix good_analytics.gen.migration` and `mix pgflow.gen.helpers_migration`.
- [ ] 2.8 Add `mix dripdrop.stamp` task that adopts an existing `dripdrop` schema into ecto_evolver tracking (mirrors `mix pgflow.stamp`).
- [ ] 2.9 Add `mix dripdrop.check_schema` task that verifies the current schema matches the latest version registered with `DripDrop.Migration` (mirrors `mix pgflow.check_schema`).
- [ ] 2.10 Add `mix dripdrop.gen.key` task that prints a base64-encoded AES-256 key for `DRIPDROP_ENCRYPTION_KEY`.
- [ ] 2.11 Add `mix dripdrop.uninstall` task that emits a `DROP SCHEMA dripdrop CASCADE` script (does not run it; operator must confirm).
- [ ] 2.12 Property test: every tenant-scoped query helper rejects calls without a `tenant_key` when one would be required (cross-tenant leakage guard).

## 3. Encryption (capability: cross-cutting)

- [ ] 3.1 Implement `DripDrop.Vault` (Cloak vault) reading `DRIPDROP_ENCRYPTION_KEY` from env at boot.
- [ ] 3.2 Implement `DripDrop.Encrypted.Map` (`use Cloak.Ecto.Map, vault: DripDrop.Vault`).
- [ ] 3.3 Implement `mix dripdrop.rotate_key OLD_KEY=... NEW_KEY=...` that streams `channel_adapters` and `http_hooks` rows in batches, decrypting with old and re-encrypting with new under a single transaction per batch.
- [ ] 3.4 Implement redaction helper `DripDrop.Redact.scrub/2` used everywhere snapshots are persisted (default regex list configurable via `config :dripdrop, redaction_patterns`).

## 4. Sequence authoring (capability: sequence-authoring)

- [ ] 4.1 Implement `DripDrop.Sequence` Ecto schema and changeset with `tenant_key`/`key` uniqueness logic.
- [ ] 4.2 Implement `DripDrop.SequenceVersion` schema + activation changeset (`activate_sequence_version/1` runs both demote-and-promote in one `Ecto.Multi`).
- [ ] 4.3 Implement `DripDrop.Step` schema with embedded `DripDrop.Timing` schema (immediate/delay/cron/event types) and validations from the spec.
- [ ] 4.4 Implement `DripDrop.Timing.parse_human_friendly/1` for the documented expressions (`@daily`, `every monday at 9am`, `in 3 days`) and `DripDrop.Timing.calculate_next_run/2` for all four timing types.
- [ ] 4.5 Implement `DripDrop.StepTransition` schema with `condition_mode: "always" | "all" | "any"` and priority ordering.
- [ ] 4.6 Implement `DripDrop.Condition` schema with type-specific validation; reject `condition_type` values outside the registered set.
- [ ] 4.7 Implement `DripDrop.SequenceAuthoring.validate_sequence_version/1` covering: entry path, adapter references, condition operands, cron expressions, hook references — exhaustive scenarios from the spec.
- [ ] 4.8 Implement public API: `DripDrop.create_sequence/1`, `create_sequence_version/2`, `activate_sequence_version/1`, `create_step/2`, `create_step_transition/2`, `create_condition/2`.
- [ ] 4.9 Tests: every authoring scenario in `specs/sequence-authoring/spec.md`, including duplicate-key-per-tenant, two-active-version rejection, fail-closed coercion telemetry assertion.

## 5. Hooks (capability: hooks)

- [ ] 5.1 Define `DripDrop.HookBehavior` with `handle_hook/3`.
- [ ] 5.2 Implement `DripDrop.HttpHook` schema with `auth_config` encrypted via `DripDrop.Encrypted.Map`, `timeout_ms` (default 5000, max 30000), `retry_count` (default 2, max 5).
- [ ] 5.3 Implement `DripDrop.Hooks.Evaluator` that:
  - Resolves `:hook_function` against `sequence.hook_module` and invokes inside a `Task.async/1` guarded with `Task.yield/2 + Task.shutdown/1` so the timeout is hard.
  - Resolves `:http_hook_id` by fetching the row, rendering URL/body via the `templates` capability, calling `Req.request/1` with `:receive_timeout`, applying retry-with-backoff up to `retry_count`, and coercing the response to `response_type`.
  - Caches results per `step_execution_id` in a `:persistent_term` or `Process.put/2` scoped map.
- [ ] 5.4 Implement `DripDrop.test_http_hook/2` that runs an evaluator pass outside any enrollment and stores `last_test_at` / `last_test_result` (with redaction).
- [ ] 5.5 Public API: `DripDrop.create_http_hook/2`, `update_http_hook/2`, `test_http_hook/2`, `list_http_hooks/1`.
- [ ] 5.6 Tests: every scenario in `specs/hooks/spec.md`, including hard timeout, hook-raise telemetry, caching across condition+template, coercion failure.

## 6. Templates (capability: templates)

- [ ] 6.1 Implement `DripDrop.Templates.Renderer` with `render/3 :: (template, vars, channel) :: {:ok, payload} | {:error, reason}`.
- [ ] 6.2 Implement Solid (Liquid) backend with strict mode disabled and a custom missing-variable handler that emits the `[:dripdrop, :template, :missing_variable]` event.
- [ ] 6.3 Implement EEx backend (module-only) used when `step.template_type == "module"`.
- [ ] 6.4 Implement MJML compile step gated on `step.config["body_format"] == "mjml"` or detection of leading `<mjml>` tag; map errors to `{:error, %{kind: :permanent, reason: {:mjml_compile, _}}}`.
- [ ] 6.5 Implement `DripDrop.Templates.Variables` resolver merging step config → hook results → enrollment data → system variables (override order from spec).
- [ ] 6.6 Per-channel payload validators (email, sms, webhook, pubsub, slack, telegram) producing the documented payload shape and validating sms-too-long / empty-body / chat-id presence.
- [ ] 6.7 Implement `DripDrop.Templates.validate/2` for authoring-time syntax validation; wire into `validate_sequence_version/1`.
- [ ] 6.8 Tests: every scenario in `specs/templates/spec.md`, plus property test that arbitrary Liquid input never raises (only returns `{:error, ...}` or empty-string-substitutions).

## 7. Channel adapters (capability: channel-adapters)

- [ ] 7.1 Implement `DripDrop.ChannelAdapter` schema with `credentials` and `config` types, `validate_credentials` callback hook into the channel's module.
- [ ] 7.2 Implement `(channel, tenant_key)` partial-unique-default constraint via a deferred trigger that flips defaults atomically.
- [ ] 7.3 Define `DripDrop.Channel` behavior with `deliver/3`, `validate_credentials/1`, `webhook_routes/1`, `verify_signature/2`.
- [ ] 7.4 Implement `DripDrop.Channels.Email` plus per-provider sub-modules using Swoosh where adapters exist (`Mailgun`, `SendGrid`, `Postmark`, `MailerSend`, `SES`, `SMTP`); map provider errors to `:temporary | :permanent` taxonomy. Each sub-module exposes `validate_credentials/1`, `deliver/3`, `verify_signature/2` (when the provider has webhooks), `webhook_routes/1`.
- [ ] 7.4a Implement `DripDrop.Channels.Email.Gmail` (Google Gmail API, `users.messages.send`): call `token_callback` MFA before send, cache token until `expires_at`, build base64-url-encoded RFC 5322 message, surface `{:error, %{kind: :permanent, reason: {:token_callback, :revoked}}}` on auth failures. **OAuth flows are explicitly out of scope** — host owns the callback.
- [ ] 7.4b Implement `DripDrop.Channels.Email.Ms365` (Microsoft Graph `/users/{user}/sendMail`): same token-callback pattern as Gmail, build Graph JSON payload shape (`message: %{subject, body: %{contentType, content}, toRecipients: [...], ...}`).
- [ ] 7.4c Implement `DripDrop.Channels.register/3` for host-registered custom providers (e.g., Resend, MailerSend variants, internal providers). Registration registers in a `:persistent_term` keyed by `{channel, provider}`; `channel_adapters` changeset consults the registry alongside built-ins.
- [ ] 7.4d Property test: token-callback adapters cache tokens until `expires_at`, refresh on the next send after expiry, and never call the callback more than once per send when `expires_at` is in the future.
- [ ] 7.5 Implement `DripDrop.Channels.SMS` with `Twilio` and `AwsSns` providers; pass `Idempotency-Key` to Twilio.
- [ ] 7.6 Implement `DripDrop.Channels.Webhook` (no provider distinction; renders URL/method/body/headers via `templates`).
- [ ] 7.7 Implement `DripDrop.Channels.PubSub` (uses `Phoenix.PubSub` from host).
- [ ] 7.8 Implement `DripDrop.Channels.Slack` (`webhook` provider).
- [ ] 7.9 Implement `DripDrop.Channels.Telegram` (`bot_api` provider).
- [ ] 7.10 Implement `DripDrop.ChannelAdapters.select/3` covering the step → sequence → tenant default → global default chain plus weighted rotation with sticky-retry semantics.
- [ ] 7.11 Public API: `DripDrop.create_channel_adapter/1`, `update_channel_adapter/2`, `list_channel_adapters/1`, `get_default_adapter/2`.
- [ ] 7.12 Tests: every scenario in `specs/channel-adapters/spec.md`, plus a contract test that every shipping channel implements all behavior callbacks and round-trips a fixture payload.

## 8. Short links (capability: short-links)

- [ ] 8.1 Define `DripDrop.ShortLinks.Adapter` behavior, `Request` and `Result` structs.
- [ ] 8.2 Implement `DripDrop.ShortLinks.Pipeline` with steps: extract → eligibility filter → enrich (UTM) → resolve via adapter (with idempotency cache lookup) → rewrite → persist `short_links` row.
- [ ] 8.3 Implement HTML rewriter using Floki, only `href`/`src` attributes, skipping `<style>`/`<script>`/comments.
- [ ] 8.4 Implement plain-text rewriter that handles trailing punctuation safely (test: `Visit https://example.com.` rewrites with the period preserved).
- [ ] 8.5 Implement `DripDrop.ShortLinks.Dub` adapter (POST to Dub API with documented field mapping).
- [ ] 8.6 Implement `DripDrop.ShortLinks.GoodAnalytics` adapter (in-process call to `GoodAnalytics.create_link/1`); fall back to instructive error when `:good_analytics` is not loaded.
- [ ] 8.7 Implement `DripDrop.ShortLinks.Module`, `DripDrop.ShortLinks.Webhook`, `DripDrop.ShortLinks.None`.
- [ ] 8.8 Implement config cascade resolver (global → tenant → sequence → step) and exclusion-pattern merging.
- [ ] 8.9 Implement `on_error: :send_originals` fallback path, recording flag in `step_executions.response.short_links_fallback`.
- [ ] 8.10 Tests: every scenario in `specs/short-links/spec.md`, plus property test that extracted-then-rewritten HTML preserves byte-equality outside `href`/`src`.

## 9. Messaging policy (capability: messaging-policy)

- [ ] 9.1 Implement `DripDrop.Suppressions` with normalize-and-upsert semantics keyed on `(channel, recipient_normalized)`; per-channel normalizers (`email`/`sms`/`webhook`/`slack`/`telegram`).
- [ ] 9.2 Implement `DripDrop.Policy.Gate` that runs as the FIRST in-dispatch policy step, checking suppression before rendering.
- [ ] 9.3 Implement RFC 8058 header injection in `DripDrop.Policy.UnsubscribeHeaders` invoked between render and adapter send for `operating_mode: "bulk"` email steps; refuse to start if `unsubscribe_url_builder` is unconfigured AND any sequence has bulk email steps.
- [ ] 9.4 Implement `DripDrop.Policy.QuietHours` with recipient timezone resolution (`enrollment.data["timezone"]` → channel-specific fallback → tenant default), TCPA SMS default 8 AM–9 PM, deferral via re-scheduling.
- [ ] 9.5 Implement `DripDrop.Policy.RateLimit` token-bucket (Postgres advisory locks default; Redis adapter behavior for opt-in) at four scopes simultaneously; emit telemetry on hits; defer (do not fail) on hit.
- [ ] 9.6 Implement `DripDrop.Policy.BounceComplaintThresholds` running asynchronously (every minute) over rolling 30-day window per adapter; emit `complaint_threshold` / `bounce_threshold` events and set `channel_adapters.config["paused_until"]` when exceeded.
- [ ] 9.7 Implement cold-outbound mode validation (rejects HTML body, daily-cap deferral, sender-domain isolation check, `recipient_verified_at` requirement).
- [ ] 9.8 Implement audit-snapshot redaction in `DripDrop.Redact.scrub/2` (called on payload + response before insert).
- [ ] 9.9 Tests: every scenario in `specs/messaging-policy/spec.md`, including 0.3% complaint threshold, 2% bounce threshold, TCPA quiet hours timezone shift, sticky cold-outbound daily cap.

## 10. Dispatch execution (capability: dispatch-execution)

- [ ] 10.1 Define `DripDrop.Scheduler` behavior; implement `DripDrop.Schedulers.Pgflow` (calls `PgFlow.enqueue/2`) and `DripDrop.Schedulers.Oban` (queue: `:dripdrop`).
- [ ] 10.2 Implement `DripDrop.Jobs.DispatchStep` with `perform/1` that:
  1. Claims the row via `UPDATE ... WHERE id = $1 AND state = 'scheduled' RETURNING *`.
  2. Loads enrollment + step + adapter context.
  3. Calls `DripDrop.Policy.Gate.check/1`; on `:skip`, transitions `→ skipped`, schedules next.
  4. Calls `DripDrop.Hooks.Evaluator.resolve/2` and caches results.
  5. Calls `DripDrop.Templates.Renderer.render/3`.
  6. Calls `DripDrop.Policy.UnsubscribeHeaders.apply/2` (email-bulk only).
  7. Calls `DripDrop.ShortLinks.Pipeline.run/2`.
  8. Calls `DripDrop.Channel.deliver/3`.
  9. Persists `payload` (redacted), `response` (redacted), `provider_message_id`; transitions `→ sent` or `→ failed`.
  10. Resolves `step_transitions` and schedules next step or completes enrollment.
- [ ] 10.3 Compute idempotency keys via documented formula; pass through to providers that support `Idempotency-Key`.
- [ ] 10.4 Implement `DripDrop.Jobs.CronTick` (PgFlow job) that runs every minute when pg_cron is unavailable.
- [ ] 10.5 Implement `DripDrop.Dispatch.Concurrency` allowing per-channel and per-adapter concurrency caps via configured worker pools.
- [ ] 10.6 Implement DB-level state-machine trigger function `dripdrop.check_step_execution_state()` rejecting illegal transitions.
- [ ] 10.7 Implement `DripDrop.Dispatch.replay/1` that bumps `attempt_window` to force a fresh idempotency key for an admin-initiated retry.
- [ ] 10.8 Tests: every scenario in `specs/dispatch-execution/spec.md`, plus a chaos test that kills the worker mid-send (after provider call, before commit) and asserts no duplicate provider message.

## 11. Enrollment lifecycle (capability: enrollment-lifecycle)

- [ ] 11.1 Implement `DripDrop.Enrollment` schema with state machine constants and explicit transitions.
- [ ] 11.2 Implement `DripDrop.enroll/1` as a single `Ecto.Multi`: insert enrollment + insert first `step_executions` row + scheduler enqueue.
- [ ] 11.3 Implement `DripDrop.unenroll/3`, `pause_enrollment/1`, `resume_enrollment/1` — paused enrollments cancel pending `step_executions` and re-schedule on resume.
- [ ] 11.4 Implement `DripDrop.track_event/3` accepting either `enrollment_id` or `%{subscriber_type, subscriber_id}` map.
- [ ] 11.5 Implement event-trigger dispatch: when an event matches a step with `timing.type = "event"`, schedule that step within the next worker tick.
- [ ] 11.6 Implement `DripDrop.list_active_enrollments/1`, `get_enrollment/3` query helpers.
- [ ] 11.7 Tests: every scenario in `specs/enrollment-lifecycle/spec.md`, including the re-enrollment idempotency case and tenant-mismatch rejection.

## 12. Event ingestion (capability: event-ingestion)

- [ ] 12.1 Implement `DripDrop.Web.WebhookPlug` (Plug-based, framework-agnostic) that dispatches to per-provider handlers based on path segments.
- [ ] 12.2 Implement `DripDrop.Web.Router.dripdrop_webhooks/1` macro that mounts a base path inside Phoenix Router with the plug.
- [ ] 12.3 Implement signature verification per webhook-pushing provider: Mailgun (HMAC-SHA256 of timestamp+token), SendGrid (Ed25519), Postmark (basic auth), MailerSend (HMAC-SHA256 with `Signature` header), Twilio (HMAC-SHA1 of URL+sorted params), SES (SNS-verified). Document explicitly that `gmail`, `ms365`, `smtp`, `pubsub`, `slack`, and `telegram` do NOT register webhook ingest routes for delivery events — for those providers the `sent` state is the terminal positive signal.
- [ ] 12.4 Implement event normalization into `message_events` rows; map provider events to the canonical `event_type` enum.
- [ ] 12.5 Implement `(provider, provider_event_id)` deduplication via partial unique index; convert violation to `200` with telemetry event.
- [ ] 12.6 Implement bounce/complaint/unsubscribe → suppression upsert in single `Ecto.Multi` transaction.
- [ ] 12.7 Implement reply detection routing via configured `DripDrop.OnReply` callback (default: pause enrollment for cold-outbound, no-op for transactional).
- [ ] 12.8 Tests: every scenario in `specs/event-ingestion/spec.md`, including invalid signature, unmatched event id, soft-vs-hard bounce, reply detection, duplicate event 200 no-op.

## 13. Public API surface and documentation

- [ ] 13.1 Implement top-level `DripDrop` module re-exporting the documented public API (sequences, versions, steps, conditions, adapters, hooks, enrollments, events, replay).
- [ ] 13.2 Add `@doc` and `@spec` for every public function, including a worked example.
- [ ] 13.3 Document `DripDrop.Telemetry` event names, metadata maps, and recommended Phoenix.Telemetry attachments.
- [ ] 13.4 Author `guides/installation.md`, `guides/cold_outbound.md`, `guides/lifecycle_email.md`, `guides/quiet_hours.md`, `guides/short_links.md`, `guides/operations.md`.
- [ ] 13.5 Author `guides/extending.md`: how to write a custom channel adapter, custom short-link adapter, custom scheduler, custom hook module. Include a dedicated **"Adding a new email provider"** section walking through the four-step recipe (Swoosh adapter or direct API → `validate_credentials/1` → signature verifier if applicable → `DripDrop.Channels.register/3`).
- [ ] 13.5a Author `guides/oauth_providers.md` covering the `token_callback` contract for Gmail and MS365: what the MFA must return, how token caching works, error taxonomy. Show three worked examples — (a) hand-rolled with `Req` and a refresh token in env, (b) using [Tango](https://github.com/agoodway/tango) (recommended companion library — explicitly NOT a DripDrop dependency; ~10 lines: `Tango.Connection.get_by_external_id/1` adapter), (c) using Ueberauth + a host-owned refresh job. State plainly that DripDrop never reads OAuth client secrets, never persists refresh tokens, and never makes refresh requests.
- [ ] 13.6 Generate ExDoc; publish to `dripdrop.dev` (or `hexdocs.pm` once published to Hex).

## 14. Demo application (capability: demo-app)

- [ ] 14.1 Generate `demo/` Phoenix 1.8 + LiveView 1.1 app via `mix phx.new demo --module DripdropDemo --app dripdrop_demo --live` (run from a scratch dir, then move into the repo as a sibling to `lib/`).
- [ ] 14.2 Edit `demo/mix.exs` to declare `{:dripdrop, path: ".."}`, mirror the library's `mix quality` alias and quality deps, set `preferred_envs: [precommit: :test, quality: :test]`, and add `seed: ["run priv/repo/seeds.exs"]` to aliases.
- [ ] 14.3 Configure `demo/config/dev.exs` to point at the Docker Postgres instance (`localhost:54324`, `dripdrop_dev`); add `config :dripdrop, repo: DripdropDemo.Repo, scheduler: DripDrop.Schedulers.Pgflow`.
- [ ] 14.4 Wire `demo/lib/dripdrop_demo/application.ex` to start a host PgFlow with `jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]`, plus call `DripDrop.startup_check/0`.
- [ ] 14.5 Mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token` in `DripdropDemoWeb.Endpoint` / `Router`.
- [ ] 14.6 Configure `unsubscribe_url_builder` and `unsubscribe_secret` in demo config so RFC 8058 round-trip works against a local SMTP/Mailgun-test inbox.
- [ ] 14.7 Implement scenario LiveView `DripdropDemoWeb.Scenarios.OnboardingLive` matching README example 1 (welcome email → 5-min PubSub → 1-day conditional reminder → Monday-9am cron digest → 7-day enterprise SMS); subscribe to PubSub for live state updates.
- [ ] 14.8 Implement `DripdropDemoWeb.Scenarios.LeadNurtureLive` matching README example 2 (HTTP-hook-driven branching, Slack notify, CRM webhook). Include a tiny mock HTTP-hook server in `demo/lib/dripdrop_demo/mock_hooks.ex` so the scenario runs offline.
- [ ] 14.9 Implement `DripdropDemoWeb.Scenarios.MultiChannelTrialLive` matching README example 3 (email + SMS + PubSub + Telegram fan-out).
- [ ] 14.10 Implement read-only dashboard LiveViews under `/dashboard/*`: `SequencesLive`, `EnrollmentsLive` (cursor-paginated, filterable by sequence/state), `ExecutionsLive` (last 24h), `EventsLive` (last 24h `message_events`). NO create/update/delete buttons.
- [ ] 14.11 Mount `Phoenix.LiveDashboard` at `/phx-dashboard` for OTP introspection.
- [ ] 14.12 Implement `priv/repo/seeds.exs` (run via `mix demo.seed`): idempotent (`Ecto.Multi.upsert/4` on stable keys); creates one email adapter (Mailgun-sandbox or local Mailpit), one SMS adapter (Twilio test SID), all three sequences with their steps/transitions/conditions, fixture subscribers, and one HTTP hook pointing at the local mock server.
- [ ] 14.13 Author `demo/README.md` documenting the run loop: prerequisites, `docker compose up -d` from the repo root, `mix setup`, `mix demo.seed`, `mix phx.server`, scenario URLs, dashboard URLs, and the offline / no-Docker fallback path.
- [ ] 14.14 Link `demo/README.md` from the top-level `README.md`.
- [ ] 14.15 Smoke test: `make ci-demo` (or equivalent CI step) runs `docker compose up -d`, `cd demo && mix setup && mix demo.seed && mix test` to confirm the demo's own tests pass.

## 14a. Cross-cutting integration tests

- [ ] 14a.1 `test/integration/full_stack_test.exs` boots the full stack (in-process PgFlow + dispatch worker + ingest plug) using the demo's mock-hooks endpoint, and exercises: enroll → policy gate → render → short-links → adapter → ingest provider event → suppression upsert → next step. Runs against the Docker Postgres image.
- [ ] 14a.2 Provider-stub integration tests in `test/integration/providers/` (Bypass-based) per channel: Mailgun, SendGrid, Twilio, Slack webhook, Telegram bot API. Each verifies signature handling on inbound events.
- [ ] 14a.3 Chaos integration test: kill a dispatch worker mid-send (after provider call, before commit) and assert the retry produces the same `provider_message_id` (idempotency invariant).

## 15. Validation and release

- [ ] 15.1 Run `openspec validate add-dripdrop-foundation` — must pass.
- [ ] 15.2 Run `mix quality` at repo root and inside `demo/` — must pass (warnings-as-errors, format check, sobelow, ex_dna, doctor, credo strict).
- [ ] 15.3 Run full test suite under Postgres 17 with pgmq + pg_cron via the Docker image.
- [ ] 15.4 Run full test suite under Postgres 17 WITHOUT pg_cron (verify `CronTick` fallback) — second CI matrix entry.
- [ ] 15.5 Run dialyzer with no warnings.
- [ ] 15.6 Manual deliverability smoke from the demo: enroll a fixture subscriber whose email is a mailbox you control, dispatch a real Mailgun-sandbox cold campaign of 25 messages from a warmed sender; verify SPF/DKIM/DMARC pass, List-Unsubscribe and List-Unsubscribe-Post headers are present in Gmail's "Show original" view, and one-click POST to the demo's `/u/:token` writes a suppression row.
- [ ] 15.7 Update top-level `README.md` with installation quickstart that points at `guides/installation.md` and at `demo/README.md`.
- [ ] 15.8 Tag `v0.1.0`, run `openspec archive add-dripdrop-foundation`, publish to Hex (or to a private registry); verify `demo/` is excluded from the published package.
