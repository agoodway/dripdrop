# Adapter Pools

## Purpose

Define tenant-scoped adapter pools that select, pin, and manage outbound sender adapters for cold outbound enrollments.

## Requirements


### Requirement: Adapter Pools Are First-Class Tenant-Scoped Entities

The system SHALL persist `dripdrop.adapter_pools` rows with `id`, `tenant_key`, `name`, `on_pin_unavailable` (`pause | reassign`, default `pause`), `metadata` (JSONB), `inserted_at`, `updated_at`. Pool names SHALL be unique per `(tenant_key, name)` with a partial unique index for global (`tenant_key IS NULL`) and tenant-scoped pools. Pools SHALL inherit the tenant scope of their owning sequence at selection time; cross-tenant pool sharing is NOT supported.

#### Scenario: Pool created and queried per tenant
- **WHEN** an operator calls `DripDrop.create_adapter_pool(%{tenant_key: "acct_a", name: "primary_outbound", on_pin_unavailable: "pause"})`
- **THEN** a row is inserted into `dripdrop.adapter_pools`, the pool is queryable via `DripDrop.list_adapter_pools(%{tenant_key: "acct_a"})`, and `DripDrop.list_adapter_pools(%{tenant_key: "acct_b"})` does NOT return it.

#### Scenario: Cross-tenant pool reference rejected
- **WHEN** a sequence with `tenant_key: "acct_a"` declares `config["pool_id"] = pool_b.id` where `pool_b.tenant_key == "acct_b"`
- **THEN** sequence-version validation returns `{:error, :pool_tenant_mismatch}` and the version cannot be activated.

### Requirement: Pool Members Carry A Class Discriminator And A Weight

The system SHALL persist `dripdrop.adapter_pool_members` rows with `pool_id`, `adapter_id`, `class` (`mailbox | esp_api`), `weight` (integer, default 1, CHECK `weight > 0`), `active` (boolean, default true), `inserted_at`, `updated_at`. The `class` discriminator drives class-specific cap math during dispatch. A given `adapter_id` MAY belong to multiple pools but only once per `(pool_id, adapter_id)` (enforced via unique index).

#### Scenario: Mailbox-class member added with weight
- **WHEN** `DripDrop.add_pool_member(pool.id, %{adapter_id: gmail_adapter.id, class: "mailbox", weight: 3})` is called against an adapter with `channel == "email"` and `provider == "gmail"`
- **THEN** the row is inserted and the WDRR allocator weights this adapter 3:1 against equivalent-class members with weight 1.

#### Scenario: ESP-class adapter rejected for mailbox-class slot
- **WHEN** `DripDrop.add_pool_member(pool.id, %{adapter_id: mailgun_adapter.id, class: "mailbox"})` is called against a SendGrid/Mailgun adapter
- **THEN** the changeset returns `{:error, :class_mismatch}` because ESP-API adapters don't satisfy mailbox-class cap math (per-`sender_mailbox` daily cap + min-gap).

#### Scenario: Same adapter in multiple pools
- **WHEN** an adapter is added as a member of `pool_a` and `pool_b`
- **THEN** both insertions succeed; the adapter's daily cap, min-gap, and health state are shared across both pools because they live on the adapter itself.

### Requirement: Pool Selection Uses Weighted Deficit Round Robin At Enrollment Time

When an enrollment is created against a sequence-version whose `mode == "outbound"` and whose `config["pool_id"]` is set, the system SHALL run a Weighted Deficit Round Robin selection across the pool's `active = true` members whose adapter is in health state `active | ramping | probing` and has remaining daily-cap headroom. The chosen adapter SHALL be persisted to `enrollments.adapter_id` atomically with the enrollment insert. WDRR deficit counters live in ETS keyed on `(pool_id, sequence_version_id, adapter_id)` and are reset on application restart.

#### Scenario: WDRR distributes fresh enrollments by weight
- **WHEN** a pool has members `[gmail_a:3, gmail_b:1]` and 4 enrollments are created in sequence
- **THEN** approximately 3 of the 4 enrollments pin `gmail_a` and 1 pins `gmail_b` (deterministic deficit-counter distribution; exact ordering depends on initial deficit state).

#### Scenario: Resting members are skipped
- **WHEN** the pool has members `[gmail_a, gmail_b]` and `gmail_a.health_state == "resting"` with `resting_until` 24 hours in the future
- **THEN** WDRR skips `gmail_a` and pins all new enrollments to `gmail_b` until `gmail_a` transitions out of resting.

#### Scenario: Restart resets fairness state without breaking selection
- **WHEN** the application restarts mid-day with active enrollments distributed across `gmail_a` and `gmail_b`
- **THEN** ETS deficit counters reset to zero; WDRR selection continues normally and converges back to weight-proportional distribution within the next ~5–10 enrollments.

### Requirement: Pool Exhaustion Pauses The Enrollment With An Operator-Visible Reason

When pool selection finds zero eligible members (every adapter is `resting` or capped or evicted) and `pool.on_pin_unavailable == "pause"`, the system SHALL fail enrollment creation with `{:error, %{reason: :pool_exhausted, pool_id: pool.id, evicted_adapter_ids: [...]}}` and emit `[:dripdrop, :dispatch, :pool_exhausted]` telemetry. When `pool.on_pin_unavailable == "reassign"` and the pool has at least one member regardless of health state, selection MAY proceed against the least-unhealthy member with explicit reassignment-event logging.

#### Scenario: Pause behavior on full eviction
- **WHEN** a pool's only two members are both `resting_until` 7 days in the future and `pool.on_pin_unavailable == "pause"`
- **THEN** `DripDrop.enroll/1` returns `{:error, %{reason: :pool_exhausted, ...}}`, the enrollment is NOT created, and `[:dripdrop, :dispatch, :pool_exhausted]` fires with `pool_id`, `evicted_adapter_ids`, `tenant_key`.

#### Scenario: Reassign behavior with explicit thread-break
- **WHEN** `pool.on_pin_unavailable == "reassign"` and selection picks `gmail_b` after `gmail_a` (the previously-pinned adapter for an enrollment that was paused mid-sequence) became permanently inactive
- **THEN** the new enrollment receives `gmail_b` as its pinned adapter, an `:enrollment_event :sender_reassigned` is logged with `from_adapter_id: gmail_a.id, to_adapter_id: gmail_b.id`, and follow-up steps for that enrollment do NOT stamp `In-Reply-To` referencing the pre-reassign chain.

### Requirement: Pool Mutations Honor Tenant Boundaries And Active Enrollments

Removing a pool member SHALL NOT automatically rebalance existing enrollments — pinned enrollments continue to use their pinned adapter regardless of pool membership changes. Operators SHALL re-pin manually if needed via `DripDrop.repin_enrollment/2`. Deleting a pool with active outbound enrollments referencing it SHALL fail unless the operator explicitly passes `force: true` (with corresponding telemetry).

#### Scenario: Pool member removal preserves existing pins
- **WHEN** `gmail_a` is removed from a pool but 50 enrollments are pinned to it
- **THEN** removal succeeds (the membership row is deleted), but the 50 enrollments continue to dispatch through `gmail_a` because their pin is on `enrollments.adapter_id`, not on the pool membership.

#### Scenario: Pool deletion guarded by active enrollments
- **WHEN** an operator calls `DripDrop.delete_adapter_pool(pool.id)` against a pool that has active outbound enrollments
- **THEN** the operation returns `{:error, %{reason: :pool_in_use, active_enrollment_count: 50}}` and the pool is preserved; passing `force: true` succeeds and emits `[:dripdrop, :pool, :force_deleted]` telemetry with the count.
