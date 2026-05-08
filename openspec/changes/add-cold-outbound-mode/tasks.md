## 0. Prerequisites

- [ ] 0.1 Confirm `add-dripdrop-foundation` change is archived (or all 9a foundation patches are merged) before starting this change. Verify `paused_until` enforcement, `recipient_domain` rate-limit scope, and rotation-clarification scenario tests are green.
- [ ] 0.2 Read `proposal.md`, `design.md`, and all 8 spec deltas in `specs/` to internalize the design decisions D1–D10. The implementation must preserve lifecycle non-regression as the primary correctness invariant (D10).

## 1. Schema migration (V02)

- [ ] 1.1 Create `lib/dripdrop/migrations/v02.ex` (EctoEvolver version 2) and register it in `DripDrop.Migration`'s `versions:` list.
- [ ] 1.2 Author `priv/dripdrop/sql/versions/v02/v02_up.sql` with: (a) new tables `adapter_pools`, `adapter_pool_members`, `adapter_sequence_budgets`; (b) new columns on `channel_adapters` (`health_state` text, `health_score` numeric, `resting_until` timestamptz, `last_send_at` timestamptz, `daily_cap` integer, `ramp_started_at` timestamptz, `ramp_increment` integer, `ramp_floor` integer, `min_gap_seconds` integer); (c) new columns on `enrollments` (`adapter_id` uuid REFERENCES `channel_adapters(id) ON DELETE RESTRICT`, `effective_mode` text); (d) new column on `sequence_versions` (`mode` text NOT NULL DEFAULT `'lifecycle'` with CHECK constraint `mode IN ('lifecycle', 'outbound')`); (e) new column on `steps` (`adapter_override_id` uuid REFERENCES `channel_adapters(id) ON DELETE SET NULL`); (f) new column on `step_executions` (`out_message_id` text); (g) new columns on `message_events` (`in_reply_to` text, `references_list` jsonb).
- [ ] 1.3 Author corresponding `v02_down.sql` reversing every change (drop tables, drop columns, drop constraints).
- [ ] 1.4 Add CHECK constraints: `health_state IN ('active', 'resting', 'probing', 'ramping')` (when not null); `health_score BETWEEN 0 AND 1` (when not null); `daily_cap > 0` (when not null); `ramp_increment > 0` (when not null); `ramp_floor >= 0` (when not null); `min_gap_seconds >= 0` (when not null); `effective_mode IN ('lifecycle', 'outbound')` (when not null); `weight > 0` on `adapter_pool_members.weight`; `max_share_pct BETWEEN 1 AND 100` on `adapter_sequence_budgets`.
- [ ] 1.5 Add unique partial indexes: `adapter_pools(tenant_key, name) WHERE tenant_key IS NOT NULL`; `adapter_pools(name) WHERE tenant_key IS NULL`; `adapter_pool_members(pool_id, adapter_id)`; `adapter_sequence_budgets(adapter_id, sequence_version_id)`.
- [ ] 1.6 Add ordinary indexes: `adapter_pool_members(pool_id) WHERE active = true`; `enrollments(tenant_key, adapter_id) WHERE adapter_id IS NOT NULL`; `enrollments(tenant_key, effective_mode) WHERE effective_mode IS NOT NULL`; `step_executions(out_message_id) WHERE out_message_id IS NOT NULL`; `message_events(in_reply_to) WHERE in_reply_to IS NOT NULL`.
- [ ] 1.7 Update `mix dripdrop.check_schema` task to verify V02 is applied; update `mix dripdrop.uninstall` to drop V02 tables and columns first.
- [ ] 1.8 Test: V02 migration up-then-down leaves the schema byte-identical to V01 (no orphan columns, indexes, or constraints).

## 2. Adapter pools (capability: adapter-pools)

- [ ] 2.1 Implement `DripDrop.AdapterPool` Ecto schema with associations to `tenant_key`, `name`, `on_pin_unavailable` (atom-typed, default `:pause`), `metadata`.
- [ ] 2.2 Implement `DripDrop.AdapterPoolMember` Ecto schema with `pool_id`, `adapter_id`, `class` (atom-typed `:mailbox | :esp_api`), `weight`, `active`. Add changeset validation rejecting `class: :mailbox` for adapters whose `provider` is in the ESP-only set (`mailgun`, `sendgrid`, `postmark`, `mailersend`, `ses`).
- [ ] 2.3 Implement `DripDrop.AdapterPools` context module with `create_adapter_pool/1`, `update_adapter_pool/2`, `delete_adapter_pool/2` (with `force:` option), `list_adapter_pools/1`, `add_pool_member/2`, `remove_pool_member/2`, `list_pool_members/1`. All functions tenant-scoped via `TenantScope.fetch!/2`.
- [ ] 2.4 Implement `DripDrop.AdapterPools.WDRR` allocator module backed by ETS keyed on `{pool_id, sequence_version_id, adapter_id}`. Module exposes `pick_member/2 :: (pool, sequence_version) :: {:ok, member} | {:error, :pool_exhausted}`. Filters members by `active = true`, adapter `health_state IN (:active, :ramping, :probing)`, and remaining ramp-aware daily-cap headroom. Updates deficit counter atomically per pick. Tests cover weight proportionality (4-pick distribution against `[a:3, b:1]` lands ~3:1).
- [ ] 2.5 Implement `DripDrop.AdapterPools.WDRR` ETS table bootstrap in `DripDrop.Application` start tree (named table, public read, write-only via the WDRR module). Restart resets the table; this is documented as a non-goal for strict cross-restart fairness continuity.
- [ ] 2.6 Public API entry points on top-level `DripDrop` module: `create_adapter_pool/1`, `update_adapter_pool/2`, `delete_adapter_pool/2`, `list_adapter_pools/1`, `add_pool_member/2`, `remove_pool_member/2`. All accept and require `tenant_key`.
- [ ] 2.7 Tests: every scenario in `specs/adapter-pools/spec.md`, including: cross-tenant pool reference rejection, mailbox-class validation, WDRR weight distribution, resting-member skip, pool exhaustion with `:pause` and `:reassign` policies, force-delete behavior, and pool-member removal preserving existing pins.

## 3. Adapter health state machine (capability: channel-adapters)

- [ ] 3.1 Add the new columns from V02 to `DripDrop.ChannelAdapter` Ecto schema: `health_state`, `health_score`, `resting_until`, `last_send_at`, `daily_cap`, `ramp_started_at`, `ramp_increment`, `ramp_floor`, `min_gap_seconds`. Use `Ecto.Enum` for `health_state` with values `[:active, :resting, :probing, :ramping]`.
- [ ] 3.2 Implement `DripDrop.AdapterHealth` module with `transition/3 :: (adapter, new_state, opts) :: {:ok, adapter, [:state_changed_event]} | {:error, :invalid_transition}`. Encode the documented state-transition matrix from `specs/channel-adapters/spec.md`. Telemetry on every transition (`[:dripdrop, :health, :state_changed]`).
- [ ] 3.3 Implement automatic `resting → probing` transition logic invoked at adapter-resolution time when `resting_until <= now()`. The probing transition records `probing_started_at` in adapter `metadata` for later probe-success / probe-failure determination.
- [ ] 3.4 Implement `DripDrop.AdapterHealth.evaluate_probe/1` (called periodically, perhaps by extending the existing `BounceComplaintThresholds` GenServer's tick) that checks adapters in `probing` state: probe-success criterion = no threshold breach in the past 24h with at least 5 sends → `probing → ramping`; probe-failure = threshold breach during probe → `probing → resting` with cooldown doubled (exponential backoff capped at 7 days).
- [ ] 3.5 Implement linear ramp formula in `DripDrop.AdapterHealth.effective_cap_today/1 :: (adapter) :: integer | nil`. Returns `nil` when no cap configured. Returns probe-phase budget (default 5, configurable via `Application.get_env(:dripdrop, :outbound_defaults)`) when `health_state == :probing`. Otherwise returns `min(daily_cap, ramp_floor + days_elapsed * ramp_increment)`.
- [ ] 3.6 Update `DripDrop.Policy.BounceComplaintThresholds` (existing module from foundation) to drive state-machine transitions instead of just writing `paused_until` to config. On breach, transition adapter `→ :resting` with `resting_until = now() + cooldown_seconds`. Repeat-breach detection (within 7 days of last `resting → probing | ramping` exit) doubles cooldown.
- [ ] 3.7 Public API: `DripDrop.set_adapter_health/2` accepting `(adapter_id, %{health_state: state, health_score: score, source: source})` for host-driven external signal injection. Validates state and score; emits `[:dripdrop, :health, :external_signal]` telemetry.
- [ ] 3.8 Atomic `last_send_at` update co-mitted with `step_execution.state → :sent` transition (extend existing `persist_success/5` in `DispatchStep`).
- [ ] 3.9 Tests: every scenario in `specs/channel-adapters/spec.md`, including: ramp formula values at days 0, 10, 30; probe phase fixed budget; threshold breach transition; exponential backoff on repeat breach; manual operator transition; lifecycle adapter ignores all new columns.

## 4. Sequence-version mode and pool reference (capability: sequence-authoring)

- [ ] 4.1 Add `mode` field to `DripDrop.SequenceVersion` Ecto schema with `Ecto.Enum` `[:lifecycle, :outbound]`. Default `:lifecycle`.
- [ ] 4.2 Update `DripDrop.SequenceAuthoring.validate_sequence_version/1` to add outbound-specific validation: when `mode == :outbound`, `config["pool_id"]` is required and must reference an existing tenant-aligned pool with at least one active member.
- [ ] 4.3 Add validation rejecting mode mutation on `state == :active` versions (mode is immutable after publish; new modes require new versions).
- [ ] 4.4 Add `adapter_override_id` field to `DripDrop.Step` Ecto schema with foreign key validation (must reference an active adapter on the same channel as the step). Reject co-occurrence with `channel_adapter_id` (foundation field).
- [ ] 4.5 Update `mix dripdrop.gen.migration` documentation/help text to mention the V02 path.
- [ ] 4.6 Tests: every scenario in `specs/sequence-authoring/spec.md`, including: outbound mode requires pool_id; empty-pool rejection; lifecycle ignores pool_id; mode immutable after publish; per-step override on lifecycle step rejected.

## 5. Enrollment-time pinning (capability: enrollment-lifecycle)

- [ ] 5.1 Add `adapter_id` and `effective_mode` fields to `DripDrop.Enrollment` Ecto schema. `effective_mode` uses `Ecto.Enum` `[:lifecycle, :outbound]` (nullable for backwards compatibility).
- [ ] 5.2 Update `DripDrop.enroll/1` (foundation) to: (a) read `sequence_version.mode`; (b) when `:outbound`, invoke `DripDrop.AdapterPools.WDRR.pick_member/2` against `sequence_version.config["pool_id"]`; (c) persist the pinned `adapter_id` and `effective_mode = :outbound` atomically with the enrollment insert in the existing `Ecto.Multi`. Lifecycle enrollments leave both columns NULL.
- [ ] 5.3 Implement `DripDrop.repin_enrollment/3 :: (enrollment_id, new_adapter_id, opts) :: {:ok, enrollment} | {:error, term()}` that updates `enrollments.adapter_id`, logs an `:enrollment_event :sender_reassigned` with the old/new adapter ids and `opts[:reason]`, and emits telemetry. Does NOT modify in-flight `step_executions`.
- [ ] 5.4 Update `DripDrop.unenroll/3`, `pause_enrollment/2`, `resume_enrollment/2` to handle outbound enrollments correctly (adapter_id remains intact across pause/resume; unenroll cancels pending executions but doesn't clear the pin in case of operator audit need).
- [ ] 5.5 Implement pool-exhaustion handling in `DripDrop.enroll/1`: when WDRR returns `{:error, :pool_exhausted}` and the pool has `on_pin_unavailable == :pause`, return `{:error, %{reason: :pool_exhausted, pool_id: pool.id, evicted_adapter_ids: [...]}}`. When `:reassign`, attempt selection against any active member regardless of health and record the reassignment.
- [ ] 5.6 Tests: every scenario in `specs/enrollment-lifecycle/spec.md`, including: lifecycle enrollment leaves columns NULL; outbound enrollment populates atomically; mid-flight version flip preserves in-progress; re-enrollment idempotency honors existing guard; manual repin records audit event.

## 6. Outbound dispatch gates (capability: dispatch-execution)

- [ ] 6.1 Implement `DripDrop.Policy.AdapterHealthCheck` module gating dispatch on `health_state IN (:active, :ramping, :probing)`. Returns `{:defer, resting_until, %{reason: "adapter_resting", ...}}` when `:resting`. Module is invoked only for `effective_mode == :outbound` enrollments.
- [ ] 6.2 Implement `DripDrop.Policy.RampCap` module computing `effective_cap_today` via `AdapterHealth.effective_cap_today/1` and counting today's sends from this adapter. Defers when sent-count ≥ effective_cap. Telemetry: `[:dripdrop, :policy, :ramp_cap]`.
- [ ] 6.3 Implement `DripDrop.Policy.SubCap` module reading `adapter_sequence_budgets` for the pinned adapter and the enrollment's sequence_version. Computes share = `floor(effective_cap_today * max_share_pct / 100)`, counts today's sends from this adapter for this sequence_version (`message_events.event_data->>'adapter_id' = $1 AND step_executions.enrollment.sequence_version_id = $2`), defers when share exhausted. Telemetry: `[:dripdrop, :policy, :sub_cap]`.
- [ ] 6.4 Implement `DripDrop.Policy.MinGap` module checking `adapter.last_send_at + min_gap_seconds <= now()`. Defers with `scheduled_for = last_send_at + min_gap_seconds` on hit. Telemetry: `[:dripdrop, :policy, :min_gap]`. Module returns `:ok` when `min_gap_seconds IS NULL`.
- [ ] 6.5 Update `DripDrop.Jobs.DispatchStep.deliver/1` to branch on `enrollment.effective_mode`: when `:outbound`, run gates in order: `AdapterHealthCheck → RampCap → SubCap → MinGap → SendingRules (with adapter_id keying) → RateLimit → Concurrency → adapter.deliver`. When `:lifecycle` or NULL, run today's foundation flow unchanged.
- [ ] 6.6 Update `DripDrop.ChannelAdapters.select/3` (or introduce `select_outbound/3`) to read `enrollment.adapter_id` directly when `effective_mode == :outbound` and step has no `adapter_override_id`. Raise `{:error, %{kind: :permanent, reason: :no_outbound_pin}}` when pin missing.
- [ ] 6.7 Implement adapter-id-keyed daily cap as a parallel check in `DripDrop.Policy.SendingRules.daily_cap_decision/3` for outbound mode: in addition to `sender_mailbox` keying, compute count via `event_data->>'adapter_id' = $adapter_id`. The stricter cap wins.
- [ ] 6.8 Implement pool-exhaustion-pause branch: when an outbound enrollment's pinned adapter becomes terminally unavailable mid-sequence (deleted, deactivated, or `resting_until > 7d`) and `pool.on_pin_unavailable == :pause`, transition the enrollment to `state = :paused` with `metadata["pause_reason"] = "pinned_adapter_unavailable"`. Telemetry: `[:dripdrop, :enrollment, :paused_pin_unavailable]`.
- [ ] 6.9 Tests: every scenario in `specs/dispatch-execution/spec.md`, including: lifecycle enrollment unaffected by outbound gates; ramp cap deferral; min-gap deferral fine-grained timing; outbound pin resolution; missing-pin failure; pool-exhaustion pause behavior.

## 7. Threading metadata and Message-ID generation (capabilities: dispatch-execution, event-ingestion, channel-adapters)

- [ ] 7.1 Implement `DripDrop.Threading` module with `generate_message_id/1 :: (sending_domain) :: binary()` returning `"<{uuidv7}@{domain}>"`. Use `Ecto.UUID.generate/0` (which on PG 18 with `uuidv7()` produces v7 ids, but Elixir-side use a v7-equivalent; verify against `:uuid_utils` or roll a simple v7 generator) to maintain k-ordering for forensic queries.
- [ ] 7.2 Update each email channel adapter (`DripDrop.Channels.Email.Mailgun`, `SendGrid`, `Postmark`, `MailerSend`, `Ses`, `Smtp`, `Gmail`, `Ms365`) to: (a) accept an optional `out_message_id` argument; (b) when set, stamp it as the outgoing message's `Message-ID:` header; (c) when the dispatch context is outbound mode, also accept `in_reply_to` and `references_list` and stamp them as `In-Reply-To` and `References` headers respectively. Confirm Swoosh adapters expose header-injection paths (most do via `Swoosh.Email.header/3`).
- [ ] 7.3 Update `DripDrop.Jobs.DispatchStep.deliver/1` outbound branch to: (a) call `Threading.generate_message_id/1`; (b) look up prior step's `step_executions.out_message_id` for this enrollment via `enrollment_id` ordered by `executed_at DESC LIMIT 1`; (c) build the `references_list` chain; (d) pass these to the channel adapter.
- [ ] 7.4 Persist `out_message_id` to `step_executions.out_message_id` atomically with the `state → :sent` transition (extend existing `persist_success/5`).
- [ ] 7.5 Update each provider webhook ingestion path (`DripDrop.Ingest.normalize/2` per-provider clauses) to extract `In-Reply-To` and `References` headers when present in the inbound payload (Mailgun, SendGrid, Postmark, MailerSend, SES inbound parses all expose headers in slightly different shapes). Persist into the new `message_events.in_reply_to` and `message_events.references_list` columns.
- [ ] 7.6 Update `DripDrop.Ingest.attach_execution/1` to prefer correlation by `step_executions.out_message_id` matching against the inbound's `In-Reply-To` value when present. Fall back to the existing `provider_message_id` correlation when no Message-ID match found.
- [ ] 7.7 Tests: outbound first-step stamps Message-ID only; follow-up step stamps full thread chain; override-step starts new thread; lifecycle email omits headers by default; lifecycle email opts in via `step.config["thread_continuity"]`.

## 8. Host-callable inbound message ingestion (capability: event-ingestion)

- [ ] 8.1 Implement `DripDrop.ingest_inbound_message/2` accepting `(adapter_id_or_tenant_scope, normalized_message_map)`. Module location: new `DripDrop.Inbound` module orchestrating correlation and routing.
- [ ] 8.2 Validate the normalized message shape via a struct or zoi-style schema: required `from`, `to`, `received_at`; optional `message_id`, `in_reply_to`, `references`, `subject`, `body_text`, `body_html`, `headers`, `intent`, `intent_data`. Reject unknown keys (or warn-and-pass via telemetry).
- [ ] 8.3 Implement correlation precedence: `in_reply_to → step_executions.out_message_id` first; fall back to `provider_message_id` lookup using the host-supplied `headers["X-Provider-Message-ID"]` or similar if available. When neither correlates, persist the event with `step_execution_id IS NULL` for forensics and emit `[:dripdrop, :ingest, :unmatched_event]`.
- [ ] 8.4 Persist a `message_events` row with `event_type` derived from `intent` (default `:reply` when correlation succeeds and intent unset). Populate `in_reply_to` and `references_list` columns from the normalized message.
- [ ] 8.5 Route to `DripDrop.OnReply.handle_reply/2` (foundation) when `event_type == :replied`. The OnReply callback hooks already handle `pause_enrollment` per step config.
- [ ] 8.6 Implement OOO rescheduling: when `intent == :ooo` and `intent_data["return_at"]` is provided as a Date, update the enrollment's currently-scheduled `step_executions.scheduled_for` to `return_at + default 9am enrollment-timezone`. Log `:enrollment_event :ooo_rescheduled`. Telemetry: `[:dripdrop, :ingest, :ooo_rescheduled]`.
- [ ] 8.7 Add `DripDrop.ingest_inbound_message/2` to the public API in `DripDrop` top-level module with `@spec` and `@doc` including a worked example showing IMAP and Microsoft Graph integration patterns.
- [ ] 8.8 Tests: every scenario in `specs/event-ingestion/spec.md`, including: IMAP-fed reply correlation via Message-ID; OOO rescheduling; unmatched inbound persisted with NULL execution; webhook ingest prefers Message-ID over provider id.

## 9. Per-(adapter, sequence) sub-cap support (capability: messaging-policy, adapter-pools)

- [ ] 9.1 Implement `DripDrop.AdapterSequenceBudget` Ecto schema with `adapter_id`, `sequence_version_id`, `weight`, `max_share_pct`, `daily_volume_target`. Defaults: `weight = 1`, `max_share_pct = 100`, `daily_volume_target = nil`.
- [ ] 9.2 Implement context module `DripDrop.AdapterSequenceBudgets` with create/update/list operations. Sub-caps are auto-created with defaults on first dispatch when missing (lazy initialization avoids forcing operators to author them upfront).
- [ ] 9.3 Wire `Policy.SubCap` (task 6.3) to read budgets and enforce the share calculation. Test: 50/50 split prevents one sequence from burning all of a 30-cap mailbox.
- [ ] 9.4 Public API: `DripDrop.set_adapter_sequence_budget/3 :: (adapter_id, sequence_version_id, attrs) :: {:ok, budget}` for operators wanting explicit control.

## 10. Spintax rendering layer (capability: templates)

- [ ] 10.1 Implement `DripDrop.Templates.Spintax` parser using a hand-written recursive descent parser (no new dependency). Supports `{a|b|c}` and nested `{{a|b} c|d}` syntax with right-to-left evaluation order.
- [ ] 10.2 Implement deterministic seed derivation: `:erlang.phash2({step_execution_id, attempt_window})` produces the PRNG seed. Use `:rand.seed/2` with the derived seed before picking. Idempotent across retries by construction.
- [ ] 10.3 Wire into `DripDrop.Templates.Renderer.render_step/3` as a post-processing layer when `step.config["template_variation"]["spintax"] == true`. Layer applies to the rendered body output (after Liquex/EEx/MJML).
- [ ] 10.4 Implement graceful degradation: malformed syntax → emit `[:dripdrop, :template, :spintax_error]` and pass original text through. Empty alternatives → filter out; warn via `[:dripdrop, :template, :spintax_warning]`.
- [ ] 10.5 Tests: every scenario in `specs/templates/spec.md`, including: deterministic per-execution output; replay produces different output; nested resolution order; malformed-input fallback; off-by-default behavior preserves literal `{...|...}` content.

## 11. Public API surface

- [ ] 11.1 Add to top-level `DripDrop` module: `create_adapter_pool/1`, `update_adapter_pool/2`, `delete_adapter_pool/2`, `list_adapter_pools/1`, `add_pool_member/2`, `remove_pool_member/2`, `list_pool_members/1`, `set_adapter_health/2`, `set_adapter_sequence_budget/3`, `repin_enrollment/3`, `ingest_inbound_message/2`. All with `@doc` (worked examples) and `@spec` (typed contracts).
- [ ] 11.2 Update README.md "Public API" section to list the new functions under a new "Cold outbound (optional)" subsection.
- [ ] 11.3 Update `mix.exs` package files list if any new dirs are introduced (none expected — all new code lives under existing `lib/dripdrop/**`).

## 12. Telemetry

- [ ] 12.1 Document new telemetry events in `DripDrop.Telemetry`: `[:dripdrop, :dispatch, :adapter_pinned]`, `[:dripdrop, :dispatch, :pool_exhausted]`, `[:dripdrop, :policy, :adapter_resting]`, `[:dripdrop, :policy, :ramp_cap]`, `[:dripdrop, :policy, :sub_cap]`, `[:dripdrop, :policy, :min_gap]`, `[:dripdrop, :health, :state_changed]`, `[:dripdrop, :health, :external_signal]`, `[:dripdrop, :ingest, :inbound_message]`, `[:dripdrop, :ingest, :ooo_rescheduled]`, `[:dripdrop, :enrollment, :paused_pin_unavailable]`, `[:dripdrop, :enrollment, :sender_reassigned]`, `[:dripdrop, :template, :spintax_error]`, `[:dripdrop, :template, :spintax_warning]`.
- [ ] 12.2 Each telemetry event has documented metadata keys in `DripDrop.Telemetry` module docs with type info (e.g., `adapter_id :: Ecto.UUID.t()`, `defer_until :: DateTime.t()`, `reason :: atom() | binary()`).

## 13. Tests — lifecycle non-regression invariant (D10)

- [ ] 13.1 Re-run the entire foundation test suite (`test/dripdrop/**` from foundation) against the V02 schema; every test MUST pass byte-identically. CI gates on this.
- [ ] 13.2 Add an integration test that creates a lifecycle sequence with rotation across 3 adapters, runs 50 enrollments end-to-end, and asserts that step-1 and step-2 of the same enrollment can land on different adapters (foundation rotation behavior preserved).
- [ ] 13.3 Add an integration test that runs the foundation's `add-dripdrop-foundation` README scenarios (Onboarding, Lead Nurture, Multi-Channel Trial) against the V02 schema with no outbound config and asserts byte-identical behavior.

## 14. Tests — outbound integration

- [ ] 14.1 End-to-end test: create an outbound sequence with a pool of 3 adapters, enroll 30 subscribers, dispatch all steps, assert (a) every enrollment uses one adapter for all its steps; (b) WDRR distributes ~10 enrollments per adapter; (c) ramp cap defers correctly when one adapter hits its limit.
- [ ] 14.2 End-to-end test: outbound sequence with `min_gap_seconds: 90`, 5 enrollments dispatching simultaneously, asserts execution timing respects the 90-second gap.
- [ ] 14.3 End-to-end test: simulated bounce events on one adapter trigger health-state transition to `:resting`, WDRR routes new enrollments around it, after `resting_until` passes the adapter probes successfully and resumes.
- [ ] 14.4 End-to-end test: outbound sequence dispatches 3 emails to one prospect, prospect replies, host pumps the IMAP-fed reply via `DripDrop.ingest_inbound_message/2`, the enrollment pauses correctly via `OnReply.handle_reply/2`, threading metadata is queryable.
- [ ] 14.5 End-to-end test: spintax enabled on a step, retry produces identical output, replay produces different output.
- [ ] 14.6 Property test: WDRR weight distribution is statistically correct over 1000 picks against `[a:5, b:3, c:2]` (~500/300/200 ± reasonable tolerance).

## 15. Documentation

- [ ] 15.1 Author `guides/cold_outbound.md` covering: when to use outbound mode vs lifecycle; pool authoring; adapter ramp planning (sample 14-day curves for new Gmail/M365 mailboxes); threading verification; the inbound-pumping integration pattern (IMAP example, Microsoft Graph subscription example, Gmail API watch example with code stubs); operator runbook for handling pool exhaustion and adapter health-state events.
- [ ] 15.2 Update `guides/installation.md` with a "Cold outbound" section linking to the new guide.
- [ ] 15.3 Update README.md "Architecture" section to document the new tables and the outbound-vs-lifecycle dispatch flow distinction.
- [ ] 15.4 Author `guides/extending.md` additions: how to register a custom pool allocator (hypothetical future), how to feed external health signals via `set_adapter_health/2`, how to integrate the host's existing inbox infrastructure with `ingest_inbound_message/2`.
- [ ] 15.5 Update demo scenarios: add a fourth scenario `OutboundLive` demonstrating a small cold sequence with a pool of two MailerSend-sandbox or local Mailpit adapters, threaded responses, and ramp visualization. **Optional** — depends on `add-dripdrop-demo-app` being archived. If both this change and the demo change are archived, this task can be addressed via a small follow-on change (`add-dripdrop-demo-cold-scenario` or similar) rather than reopening either parent change.

## 16. Validation and release

- [ ] 16.1 Run `openspec validate add-cold-outbound-mode --strict` — must pass.
- [ ] 16.2 Run `mix quality` — must pass with no warnings, format, sobelow, ex_dna, doctor, credo strict.
- [ ] 16.3 Run `mix dialyzer` — no warnings.
- [ ] 16.4 Full test suite under PG 18 with V01 + V02 applied.
- [ ] 16.5 Manual integration smoke: enroll 10 prospects in an outbound sequence using two Mailgun-sandbox adapters as the pool, verify (a) enrollment-time pinning per recipient; (b) follow-up emails carry `In-Reply-To` and `References` referencing prior steps; (c) Gmail/Outlook display the messages as a coherent thread; (d) test reply lands and pauses the enrollment.
- [ ] 16.6 Update top-level README.md changelog to document the new public API and the V02 schema.
- [ ] 16.7 Tag the change as ready-to-archive after merge: `openspec archive add-cold-outbound-mode`.
