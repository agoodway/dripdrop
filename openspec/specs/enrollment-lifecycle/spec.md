# enrollment-lifecycle

## Purpose

Enrollment lifecycle defines subscriber enrollment, state transitions, tracked events, and event-triggered progression through sequences.

## Requirements

### Requirement: Enrollment Is Idempotent Per (Sequence, Subscriber) Tuple

The system SHALL expose `DripDrop.enroll/1` that accepts a sequence reference, a polymorphic subscriber `{type, id}` (where `id` is an opaque non-empty string — UUIDs are NOT required), an optional starting step key, optional `data` JSONB, and optional `metadata` JSONB. A unique constraint on `(sequence_id, subscriber_type, subscriber_id)` SHALL prevent more than one active enrollment per tuple. Calling `enroll/1` for a tuple that already has an `active` or `paused` enrollment SHALL return `{:ok, existing_enrollment}` without inserting a new row.

#### Scenario: First-time enrollment
- **WHEN** `DripDrop.enroll(sequence_key: "saas_onboarding", subscriber: %{type: "User", id: "u_123"}, data: %{name: "Ada"})` is called
- **THEN** a new `enrollments` row is inserted with `state: "active"`, `started_at` set, and the first `step_executions` row is scheduled in the same `Ecto.Multi`.

#### Scenario: Re-enrollment is a no-op
- **WHEN** `enroll/1` is called twice in succession for the same `(sequence_id, type, id)` tuple
- **THEN** the second call returns the existing enrollment row and does NOT duplicate `step_executions` rows or PgFlow jobs.

#### Scenario: Re-enrollment after completion
- **WHEN** `enroll/1` is called for a tuple whose previous enrollment is `state: "completed"` or `state: "cancelled"`, and the sequence has `metadata.allow_reenrollment: true`
- **THEN** a new `enrollments` row is inserted and a new dispatch is scheduled.

#### Scenario: Subscriber id accepts non-UUID strings
- **WHEN** the caller provides `subscriber: %{type: "Lead", id: "lead@example.com"}`
- **THEN** the row is created with `subscriber_id: "lead@example.com"` and lookups by that string succeed.

### Requirement: Enrollment State Machine Has Explicit Transitions

The system SHALL maintain `enrollments.state` with the values `active`, `paused`, `completed`, `cancelled`. Allowed transitions are: `active ↔ paused`, `active → completed`, `active → cancelled`, `paused → cancelled`. The system SHALL reject any other transition with `{:error, :invalid_transition}`.

#### Scenario: Pause and resume
- **WHEN** `DripDrop.pause_enrollment(enrollment_id)` is called on an active enrollment, then `DripDrop.resume_enrollment(enrollment_id)`
- **THEN** the enrollment transitions `active → paused → active`, all due-but-unsent `step_executions` for that enrollment have their state moved to `cancelled` while paused (so PgFlow jobs are not stranded), and re-scheduling occurs on resume.

#### Scenario: Cancel a paused enrollment
- **WHEN** `DripDrop.unenroll(sequence_key, type, id)` is called against a paused enrollment
- **THEN** the enrollment transitions to `cancelled`, `cancelled_at` is set, and any pending `step_executions` are atomically cancelled.

#### Scenario: Reject completed → active
- **WHEN** code attempts to transition a `completed` enrollment back to `active`
- **THEN** the transition is rejected with `{:error, :invalid_transition}`.

### Requirement: Track Event Records Behavioral Signals Linked To Enrollment Or Subscriber

The system SHALL expose `DripDrop.track_event(enrollment_id_or_subscriber, event_key, event_data \\ %{})`. The function SHALL accept either an `enrollment_id` (writing the row with that link) or a `%{subscriber_type, subscriber_id}` map (writing the row without `enrollment_id` so events can be back-correlated when the subscriber later enrolls). `events` rows SHALL store `event_type` (`user_action | milestone | custom`), `event_key`, `event_data` JSONB, and `occurred_at`.

#### Scenario: Track event on an enrollment
- **WHEN** `DripDrop.track_event(enrollment.id, "viewed_pricing", %{plan: "pro"})` is called
- **THEN** an `events` row is inserted with `enrollment_id`, `subscriber_type` and `subscriber_id` denormalized from the enrollment, and `event_data: %{"plan" => "pro"}`.

#### Scenario: Track event before enrollment exists
- **WHEN** `DripDrop.track_event(%{subscriber_type: "User", subscriber_id: "u_123"}, "signed_up")` is called
- **THEN** the `events` row is inserted with `enrollment_id IS NULL`, and a later `enroll/1` for the same subscriber MAY surface that event during condition evaluation.

#### Scenario: Event-triggered step
- **WHEN** an `event_key` matches a step whose `timing.type = "event"` and `timing.trigger_event = "viewed_pricing"`
- **THEN** dispatch SHALL schedule that step within the next worker tick rather than waiting for `scheduled_for`.

### Requirement: Events Are Indexed For Fast Lookup By Subscriber

The system SHALL maintain a Postgres index on `(subscriber_type, subscriber_id, event_key, occurred_at)` for `dripdrop.events`. Lookups by these fields SHALL not require a full-table scan even with millions of rows.

#### Scenario: Lookup recent events for a subscriber
- **WHEN** the dispatcher queries `WHERE subscriber_type = 'User' AND subscriber_id = 'u_1' AND event_key = 'viewed_pricing' ORDER BY occurred_at DESC LIMIT 1`
- **THEN** Postgres uses the composite index (verified by `EXPLAIN`).

### Requirement: Tenant Scope Is Honored On Enrollment Operations

When a sequence has a non-NULL `tenant_key`, the system SHALL require the same `tenant_key` to be supplied to `enroll/1`, `unenroll/3`, `pause_enrollment/1`, `resume_enrollment/1`, and `track_event/3`, and SHALL reject operations whose tenant does not match.

#### Scenario: Tenant mismatch is rejected
- **WHEN** a sequence belongs to `tenant_key: "acct_a"` and a caller invokes `enroll/1` with `tenant_key: "acct_b"`
- **THEN** the call returns `{:error, :tenant_mismatch}` and no row is inserted.


### Requirement: Enrollments Carry An Optional Adapter Pin And Effective-Mode Snapshot

The system SHALL extend `dripdrop.enrollments` with two nullable columns: `adapter_id uuid REFERENCES dripdrop.channel_adapters(id) ON DELETE RESTRICT` (the pinned adapter for outbound enrollments; NULL for lifecycle), and `effective_mode text` (`lifecycle | outbound`, snapshotted from `sequence_version.mode` at enrollment creation time). Lifecycle enrollments SHALL leave both columns NULL (existing behavior preserved). Outbound enrollments SHALL have both columns populated atomically with the enrollment insert.

#### Scenario: Lifecycle enrollment stores no pin
- **WHEN** `DripDrop.enroll/1` creates an enrollment for a sequence with `sequence_version.mode == "lifecycle"`
- **THEN** `enrollments.adapter_id IS NULL` and `enrollments.effective_mode IS NULL` (or `"lifecycle"` for explicitness, both treated equivalently by the dispatcher).

#### Scenario: Outbound enrollment stores pin and mode atomically
- **WHEN** `DripDrop.enroll/1` creates an enrollment for a sequence-version with `mode == "outbound"` and `config["pool_id"]` set
- **THEN** the pool's WDRR allocator selects an adapter, and the enrollment, the pinned `adapter_id`, and `effective_mode = "outbound"` are inserted in a single `Ecto.Multi` transaction with the first `step_executions` row.

### Requirement: Enrollment-Time Pinning Is Final For The Enrollment Lifetime

Once an enrollment's `adapter_id` is set, the system SHALL NOT change it during normal dispatch — every step in that enrollment SHALL use the pinned adapter. Reassignment SHALL only occur through the explicit operator-driven `DripDrop.repin_enrollment/2` API, the `pool.on_pin_unavailable == "reassign"` automatic recovery path (when triggered), or operator manual mutation with audit logging. Per-step adapter overrides via `steps.adapter_override_id` SHALL apply to that step only and SHALL NOT mutate `enrollments.adapter_id`.

#### Scenario: Step override does not mutate enrollment pin
- **WHEN** an outbound enrollment has `adapter_id: gmail_a.id` and step 3 has `adapter_override_id: ceo_mailbox.id`
- **THEN** step 3 dispatches through `ceo_mailbox`, but `enrollments.adapter_id` remains `gmail_a.id`, and step 4 dispatches through `gmail_a` again.

#### Scenario: Manual repin records audit event
- **WHEN** an operator calls `DripDrop.repin_enrollment(enrollment.id, new_adapter.id, reason: "compliance_request")`
- **THEN** `enrollments.adapter_id` updates to `new_adapter.id`, an `:enrollment_event :sender_reassigned` is logged with old/new adapter ids and the reason, and subsequent step executions use the new pin.

### Requirement: Effective Mode Snapshot Insulates In-Flight Enrollments From Version Mode Flips

The system SHALL set `enrollments.effective_mode` from `sequence_version.mode` at the moment of enrollment creation and SHALL NOT update it when the sequence later activates a new version with a different mode. Existing in-flight enrollments retain their original mode for their full lifecycle. New enrollments after a mode-flip activation receive the new mode.

#### Scenario: Mid-flight version flip does not change in-progress enrollment behavior
- **WHEN** sequence X version 1 (`mode: "lifecycle"`) has 100 active enrollments, then version 2 (`mode: "outbound"`) is activated and 50 new enrollments are created
- **THEN** the original 100 continue with `effective_mode == "lifecycle"` and dispatch through the lifecycle path; the new 50 receive `effective_mode == "outbound"` and adapter pins from version 2's pool.

#### Scenario: Cancel-and-re-enroll picks up new mode
- **WHEN** an operator cancels a lifecycle enrollment and re-enrolls the same subscriber after the version flip
- **THEN** the new enrollment receives `effective_mode == "outbound"` because re-enrollment is enrollment creation against whatever version is currently active.

### Requirement: Re-Enrollment Idempotency Honors The Existing Active-Or-Paused Guard

The foundation's re-enrollment idempotency guard (unique partial index on `(tenant_key, sequence_id, subscriber_type, subscriber_id) WHERE state IN ('active', 'paused')`) SHALL apply to outbound enrollments unchanged. Pool selection and adapter pinning SHALL NOT execute when the idempotency guard rejects a duplicate enrollment attempt.

#### Scenario: Duplicate outbound enroll returns existing pin
- **WHEN** an outbound enrollment exists for `(tenant_a, seq_x, "user", "u1")` with `adapter_id: gmail_a.id`, and `DripDrop.enroll/1` is called again with the same identity
- **THEN** the existing enrollment row is returned (idempotency), pool selection does NOT run, and `gmail_a` is NOT re-rolled or rebudgeted.
