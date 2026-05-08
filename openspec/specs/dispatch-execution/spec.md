# dispatch-execution

## Purpose

Dispatch execution defines how scheduled step executions are claimed, orchestrated, retried, and advanced through the configured scheduler.

## Requirements

### Requirement: Dispatch Is A Pure Orchestrator That Delegates To Other Capabilities

The system SHALL implement a `DripDrop.Jobs.DispatchStep` PgFlow job whose ONLY responsibilities are: (a) claim a `step_execution` row via compare-and-set, (b) load the enrolment/step context, (c) call into `messaging-policy` to gate the send, (d) call into `hooks` to resolve any hook-derived variables, (e) call into `templates` to render payload, (f) call into `short-links` to rewrite URLs if configured, (g) call into `channel-adapters` to deliver, (h) persist the result and emit `message_events`, and (i) advance to the next step via `step_transitions`. Dispatch SHALL NOT contain inline policy, template, hook, short-link, or channel logic.

#### Scenario: Single in-flight execution per row
- **WHEN** two PgFlow workers attempt to claim the same `step_execution_id` simultaneously
- **THEN** the SQL `UPDATE dripdrop.step_executions SET state = 'claiming', claimed_at = now() WHERE id = $1 AND state = 'scheduled' RETURNING *` returns one row to one worker and zero rows to the other; the loser exits cleanly.

### Requirement: Step Executions Are Idempotent Via Stable Idempotency Keys

Every `step_executions` row SHALL be created with a stable, deterministic `idempotency_key` derived from `(enrollment_id, step_id, scheduled_for_truncated_to_minute, attempt_window)`. The system SHALL refuse to send the same `idempotency_key` twice. When a provider supports request-level idempotency (Mailgun, Postmark, Twilio's `Idempotency-Key`), the dispatcher SHALL pass the key through.

#### Scenario: Crash-then-retry does not double send
- **WHEN** the dispatch worker crashes after the provider HTTP call but before the database transaction commits, and PgFlow reschedules the job
- **THEN** the second attempt observes the existing row, sees `state IN ('sending', 'sent')`, queries the provider with the same idempotency key (or treats `sending` past a TTL as recoverable), and never produces a duplicate provider message.

#### Scenario: Idempotency key is stable across attempts
- **WHEN** dispatch retries the same `step_execution_id` after a transient provider failure
- **THEN** the `idempotency_key` is unchanged and is forwarded to the provider on each retry.

### Requirement: Execution States Form A Linear Acyclic Graph

`step_executions.state` SHALL take values from `scheduled | claiming | sending | sent | failed | skipped | cancelled`. Allowed transitions are: `scheduled → claiming`, `claiming → (sending | skipped | cancelled)`, `sending → (sent | failed)`, `failed → scheduled` (retry). All other transitions SHALL be rejected at the database level via a `CHECK` constraint or trigger.

#### Scenario: Skip on suppression
- **WHEN** the dispatcher claims a row, then `messaging-policy` returns `{:skip, :suppressed}`
- **THEN** the row transitions `claiming → skipped`, an entry is written to `message_events`, and the next step is scheduled (suppression on this step does not auto-cancel the enrollment).

#### Scenario: Retry budget exhausted
- **WHEN** `step_executions.retry_count >= step.config["max_retries"]` after a `failed` transition
- **THEN** the row stays in `failed` (no further `failed → scheduled` transition), and the enclosing enrollment is `cancelled` IF `step.config["on_max_retry"] == "cancel_enrollment"` (default), or the next step is scheduled IF `"continue"`.

### Requirement: Scheduler Is An Abstraction With PgFlow As Default

The system SHALL define a `DripDrop.Scheduler` behavior with `schedule/2` and `cancel/1`. Two implementations SHALL ship: `DripDrop.Schedulers.Pgflow` (default) and `DripDrop.Schedulers.Oban` (alternative). The configured scheduler is selected via `config :dripdrop, scheduler: <module>`.

#### Scenario: Default to PgFlow
- **WHEN** the host application has `pgflow` configured and DripDrop config does NOT specify `scheduler`
- **THEN** `DripDrop.Scheduler` resolves to `DripDrop.Schedulers.Pgflow` and dispatch jobs are enqueued via PgFlow.

#### Scenario: Custom scheduler
- **WHEN** the host application defines `MyApp.CustomScheduler` implementing the behavior and configures `scheduler: MyApp.CustomScheduler`
- **THEN** `DripDrop.enroll/1` calls `MyApp.CustomScheduler.schedule/2` for each `step_execution` and stores the returned job id in `step_executions.pgflow_run_id` (or equivalent).

### Requirement: Cron-Driven Steps Need pg_cron Or An External Tick

For steps whose `timing.type == "cron"`, the system SHALL rely on either `pg_cron` (when installed) to insert `step_executions` for matching enrollments, or, when `pg_cron` is unavailable, on a periodic PgFlow tick job (`DripDrop.Jobs.CronTick`) that runs every minute and seeds executions. Delay-based and event-based steps SHALL NOT require `pg_cron`.

#### Scenario: pg_cron unavailable
- **WHEN** the host has run `mix pgflow.gen.postgres_extensions_migration --no-cron` and a sequence contains a cron step
- **THEN** `mix dripdrop.setup` warns the operator and registers `DripDrop.Jobs.CronTick` with a 1-minute schedule.

#### Scenario: Cron expression with timezone
- **WHEN** a step has `timing: %{type: "cron", cron_expression: "0 9 * * MON", timezone: "America/New_York"}`
- **THEN** the next-run calculation shifts to `America/New_York`, computes the next match using `Crontab.Scheduler`, and shifts back to UTC for storage in `scheduled_for`.

### Requirement: Worker Pool Concurrency Is Configurable Per Channel And Per Adapter

The system SHALL allow operators to configure dispatch concurrency separately for each channel and for each adapter, so that one slow provider cannot starve others. Configuration SHALL be set via `config :dripdrop, dispatch: [concurrency: [email: 20, sms: 5, default: 10]]` and via `channel_adapters.config["concurrency"]` overrides.

#### Scenario: Channel-level concurrency
- **WHEN** dispatch is configured with `concurrency: [email: 20, sms: 5]` and SMS dispatch is hitting the per-adapter limit
- **THEN** new email executions continue to dispatch up to 20 concurrent workers without being blocked behind SMS work.

### Requirement: Dispatch Emits Telemetry For Every Phase

The system SHALL emit telemetry events `[:dripdrop, :dispatch, :start | :stop | :exception]` per execution and `[:dripdrop, :dispatch, :phase, :start | :stop]` for each phase (claim/policy/hooks/template/short_links/send/transition). Measurements SHALL include duration in `:native` units; metadata SHALL include `step_execution_id`, `enrollment_id`, `sequence_key`, `step_key`, `channel`, `adapter_provider`, and `tenant_key`.

#### Scenario: Telemetry around send phase
- **WHEN** dispatch enters the send phase
- **THEN** a `[:dripdrop, :dispatch, :phase, :start]` event fires with `phase: :send` and a corresponding `:stop` event fires when the channel adapter returns.


### Requirement: Outbound-Mode Dispatch Adds New Policy Gates Without Modifying The State Machine

For step executions whose enclosing enrollment has `effective_mode == "outbound"`, the system SHALL run the following additional policy gates after the foundation's `Gate` (suppression) and `QuietHours` checks and before the existing `SendingRules` and `RateLimit` checks: (a) **Adapter health check** — refuse dispatch when the pinned adapter has `health_state == "resting"` and `resting_until > now()`; (b) **Ramp cap check** — defer dispatch when today's effective ramp cap is exhausted; (c) **Per-(adapter, sequence) sub-cap check** — defer dispatch when the sequence's allocated daily share of this adapter is exhausted; (d) **Min-gap check** — defer dispatch when `now() - adapter.last_send_at < adapter.min_gap_seconds`. Each gate SHALL defer (not skip or fail) by transitioning the execution `claiming → scheduled` with `scheduled_for` set to the next eligible time. **The `step_executions` state machine SHALL NOT change** — no new states are introduced; the existing `scheduled → claiming → sending → sent | failed | skipped | cancelled` lattice handles every new gate via the existing `defer` path.

#### Scenario: Outbound gates fire only in outbound mode
- **WHEN** a lifecycle enrollment dispatches a step on an adapter that has `health_state = "resting"`, `min_gap_seconds = 90`, and recent `last_send_at`
- **THEN** none of the outbound gates fire (lifecycle path bypasses them); dispatch proceeds through the existing foundation gates only.

#### Scenario: Outbound enrollment respects ramp cap deferral
- **WHEN** an outbound enrollment's pinned adapter has consumed today's effective ramp cap (e.g., 25 sends against `effective_cap_today = 25`)
- **THEN** the next dispatch attempt defers to the next day's boundary in the configured timezone, emits `[:dripdrop, :policy, :ramp_cap]` telemetry with `adapter_id`, `effective_cap`, `sent_count`, and the execution returns to `state = "scheduled"`.

#### Scenario: Min-gap deferral is fine-grained
- **WHEN** an outbound enrollment dispatches at 10:00:30 against an adapter with `min_gap_seconds = 90` and `last_send_at = 10:00:00`
- **THEN** the execution defers to 10:01:30 (60 seconds in the future), emits `[:dripdrop, :policy, :min_gap]` telemetry, and the channel adapter is NOT called.

### Requirement: Outbound Adapter Resolution Uses Enrollment Pin

For outbound-mode enrollments, `ChannelAdapters.select/3` (or its successor that branches on mode) SHALL resolve to `enrollments.adapter_id` directly when set, without consulting `step.channel_adapter_id`, step rotation, sequence rotation, tenant default, or global default. When `steps.adapter_override_id` is set on the step, the override SHALL win and the enrollment pin SHALL be bypassed for that step only. When neither is set in outbound mode, dispatch SHALL fail with `{:error, %{kind: :permanent, reason: :no_outbound_pin}}`.

#### Scenario: Outbound resolution uses the pin
- **WHEN** an outbound enrollment with `adapter_id: gmail_a.id` dispatches a step that has neither `channel_adapter_id` nor `adapter_override_id`
- **THEN** the dispatcher resolves to `gmail_a` directly without running the foundation's selection chain.

#### Scenario: Step override beats pin
- **WHEN** an outbound enrollment with `adapter_id: gmail_a.id` dispatches a step with `adapter_override_id: ceo_mailbox.id`
- **THEN** the dispatcher resolves to `ceo_mailbox` for this step only.

#### Scenario: Missing pin fails dispatch
- **WHEN** an outbound enrollment somehow has `adapter_id IS NULL` (data inconsistency)
- **THEN** dispatch fails with `:no_outbound_pin`, the execution transitions to `failed`, and `[:dripdrop, :dispatch, :no_outbound_pin]` telemetry fires for operator alerting.

### Requirement: Outbound Email Channels Stamp RFC Threading Headers

For outbound-mode enrollments on email channels, the email channel adapter SHALL: (a) generate a fresh RFC 5322 `Message-ID` of form `<{uuidv7()}@{sending_domain}>` and stamp it as the `Message-ID:` header of the outgoing message; (b) persist the generated value to `step_executions.out_message_id` atomically with `state → "sent"` transition; (c) on follow-up steps within the same enrollment, look up the prior step's `out_message_id` and stamp `In-Reply-To: <prior_out_message_id>` and `References:` accumulating the chain. When `steps.adapter_override_id` is set on a step, the dispatcher SHALL NOT stamp `In-Reply-To` or `References` for that step (treated as a new thread). Lifecycle email sends SHALL NOT stamp these headers unless explicitly opted-in via `step.config["thread_continuity"] == true`.

#### Scenario: First outbound step stamps Message-ID only
- **WHEN** an outbound enrollment dispatches its first email step
- **THEN** the outgoing email carries a `Message-ID: <uuidv7@domain>` header, no `In-Reply-To` or `References`, and `step_executions.out_message_id` stores the value.

#### Scenario: Follow-up step stamps full thread chain
- **WHEN** the same outbound enrollment dispatches step 2 after step 1 sent successfully with `out_message_id: m1`
- **THEN** step 2's outgoing email carries `Message-ID: m2`, `In-Reply-To: <m1>`, `References: <m1>`. Step 3 carries `Message-ID: m3`, `In-Reply-To: <m2>`, `References: <m1> <m2>`.

#### Scenario: Override step breaks the chain explicitly
- **WHEN** step 3 in the same enrollment has `adapter_override_id` set
- **THEN** step 3 stamps a fresh `Message-ID: m3` but no `In-Reply-To` or `References`. Step 4 (using the original pin again) chains from `m2` (the last non-override message) — the override's `m3` is excluded from the References chain.

#### Scenario: Lifecycle email omits threading headers by default
- **WHEN** a lifecycle enrollment dispatches an email step
- **THEN** no `Message-ID:` is generated by DripDrop (the provider's own behavior is unchanged), no `In-Reply-To`/`References` are stamped, and `step_executions.out_message_id IS NULL`. Existing foundation behavior is preserved.

### Requirement: Pool-Exhaustion During Dispatch Pauses The Enrollment

When an outbound enrollment's pinned adapter transitions to a terminal unavailable state (e.g., adapter is deleted, deactivated, or enters `health_state = "resting"` with `resting_until > 7 days`) and the enclosing pool's `on_pin_unavailable == "pause"`, the dispatcher SHALL transition the enrollment to `state = "paused"` with `metadata["pause_reason"] = "pinned_adapter_unavailable"` and emit `[:dripdrop, :enrollment, :paused_pin_unavailable]` telemetry. When `on_pin_unavailable == "reassign"`, the dispatcher SHALL invoke the pool's WDRR allocator to pick another active member, update `enrollments.adapter_id`, log a `:sender_reassigned` enrollment event, and proceed without stamping `In-Reply-To` referencing the pre-reassign chain.

#### Scenario: Pause-on-unavailable preserves enrollment for operator review
- **WHEN** an outbound enrollment's pinned `gmail_a` enters `resting` with `resting_until = now() + 14 days`, the pool has `on_pin_unavailable = "pause"`, and a step dispatch attempts to use it
- **THEN** the enrollment transitions to `state = "paused"`, no send occurs, and operators see the pause reason in `enrollment.metadata`.

#### Scenario: Reassign-on-unavailable continues with thread break
- **WHEN** the same scenario but `on_pin_unavailable = "reassign"`
- **THEN** WDRR picks `gmail_b`, `enrollments.adapter_id` updates, the next step sends from `gmail_b` without `In-Reply-To` referencing the chain through `gmail_a`, and `[:dripdrop, :enrollment, :sender_reassigned]` telemetry fires with old/new adapter ids.
