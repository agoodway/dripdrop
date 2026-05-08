## ADDED Requirements

### Requirement: Sequence Versions Carry A Mode Flag

The system SHALL extend `dripdrop.sequence_versions` with a `mode` column of type text constrained to `lifecycle | outbound` with default `lifecycle` and a NOT NULL constraint after migration backfill. The mode SHALL determine which dispatch gates and adapter-resolution path the dispatcher uses for enrollments against this version.

#### Scenario: Default mode is lifecycle for backwards compatibility
- **WHEN** a sequence version is created without specifying `mode`
- **THEN** `mode` defaults to `"lifecycle"` and the dispatcher uses the foundation's adapter-resolution chain and gate set unchanged.

#### Scenario: Explicit outbound mode requires pool reference
- **WHEN** an operator creates a sequence version with `mode: "outbound"` but no `config["pool_id"]` set
- **THEN** `validate_sequence_version/1` returns `{:error, :outbound_requires_pool}` and the version cannot be activated.

#### Scenario: Mode is immutable after publish
- **WHEN** a sequence version with `mode: "outbound"` is in `state: "active"` and an operator attempts to update its mode to `"lifecycle"`
- **THEN** the changeset returns `{:error, :mode_immutable_after_publish}`. Mode changes require creating a new version with the new mode.

### Requirement: Outbound Sequence Versions Reference An Adapter Pool Through Config

The system SHALL accept `sequence_versions.config["pool_id"]` as a UUID reference to a `dripdrop.adapter_pools` row. Validation SHALL verify the referenced pool exists, has at least one active member, and shares the sequence's `tenant_key` (or pool tenant is NULL for global pools used in single-tenant deployments). The pool reference is required for `mode == "outbound"` and ignored for `mode == "lifecycle"`.

#### Scenario: Valid pool reference activates version
- **WHEN** an operator creates an outbound version with `config["pool_id"]: <existing pool id>` and the pool has 2 active members in the same tenant
- **THEN** validation succeeds and the version can be activated.

#### Scenario: Empty pool blocks activation
- **WHEN** an operator references a pool with zero active members
- **THEN** validation returns `{:error, :pool_empty}` and activation fails until at least one member is added.

#### Scenario: Lifecycle mode ignores pool_id
- **WHEN** a lifecycle version has `config["pool_id"]` set (legacy data or operator error)
- **THEN** the value is ignored at dispatch time; the foundation's selection chain runs unchanged. Validation MAY warn but SHALL NOT reject.

### Requirement: Steps Support An Optional Per-Step Adapter Override

The system SHALL extend `dripdrop.steps` with a nullable `adapter_override_id` column referencing `channel_adapters.id`. When set on a step within an outbound-mode sequence, the dispatcher SHALL use the override for that step only without mutating `enrollments.adapter_id`. The override SHALL be independently validated against the same `(channel == step.channel)` constraint as the foundation's explicit step adapter. When the override is set, the dispatcher SHALL NOT stamp `In-Reply-To` or `References` headers referencing the enrollment's prior chain — the override is treated as starting a new conversation.

#### Scenario: Override fires on a single step then returns to pin
- **WHEN** an outbound enrollment has `adapter_id: gmail_a.id` and step 3 has `adapter_override_id: ceo_mailbox.id`
- **THEN** step 1 sends from `gmail_a`, step 2 sends from `gmail_a`, step 3 sends from `ceo_mailbox` (with no `In-Reply-To` referencing step 2's `out_message_id`), and step 4 returns to `gmail_a`.

#### Scenario: Override on lifecycle step is treated as foundation's explicit step adapter
- **WHEN** a lifecycle step has both `channel_adapter_id` (foundation) and `adapter_override_id` (this change) set
- **THEN** validation rejects the conflict at authoring time. Lifecycle steps SHALL use only `channel_adapter_id`; outbound steps SHALL use only `adapter_override_id`. The two fields exist for clarity of intent and have non-overlapping authoring rules.

### Requirement: Sequence Version Validation Surfaces Outbound-Specific Errors

The system SHALL extend `validate_sequence_version/1` (foundation) with outbound-mode validation passes that check, when `mode == "outbound"`: (a) `config["pool_id"]` references an existing tenant-aligned pool with active members; (b) every step's `adapter_override_id` (when set) references an active adapter on the same channel as the step; (c) the sequence has at least one email step OR validation explicitly allows non-email outbound (default: warn but don't reject — outbound mode is meaningful for SMS sequences too).

#### Scenario: All outbound checks pass
- **WHEN** `validate_sequence_version(version_id)` runs on a fully-configured outbound version
- **THEN** the function returns `{:ok, []}` (no errors).

#### Scenario: Bad override surfaces a per-step error
- **WHEN** step 3's `adapter_override_id` references an adapter on a different channel than the step
- **THEN** validation returns `{:error, [{:step, step_3.id, :override_channel_mismatch}]}` listing the offending step.
