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
