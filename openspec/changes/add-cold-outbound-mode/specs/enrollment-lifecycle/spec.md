## ADDED Requirements

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
