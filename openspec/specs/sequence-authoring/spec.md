# sequence-authoring

## Purpose

Sequence authoring defines how sequences, versions, steps, transitions, and conditions are created, validated, and activated.

## Requirements

### Requirement: Sequences Are Created With A Stable Key And Optional Tenant Scope

The system SHALL allow callers to create a `dripdrop.sequences` row with a human name, machine-readable `key`, optional `description`, optional `hook_module` (an Elixir module string), an `active` flag, an optional `tenant_key`, and an optional `metadata` JSONB. The `(tenant_key, key)` tuple SHALL be unique; when `tenant_key` is `NULL`, `key` alone SHALL be unique among rows where `tenant_key IS NULL`.

#### Scenario: Create a sequence in single-tenant mode
- **WHEN** the caller invokes `DripDrop.create_sequence(%{name: "Onboarding", key: "saas_onboarding", hook_module: "MyApp.Hooks"})`
- **THEN** the system inserts a row with `tenant_key = NULL`, returns `{:ok, sequence}`, and rejects subsequent inserts with the same `key` and `NULL` tenant.

#### Scenario: Create the same key in different tenants
- **WHEN** two callers create sequences with `key: "onboarding"` for `tenant_key: "acct_a"` and `tenant_key: "acct_b"` respectively
- **THEN** both insertions succeed and the unique index treats them as distinct.

#### Scenario: Reject duplicate key within the same tenant
- **WHEN** `create_sequence/1` is called twice with `tenant_key: "acct_a"` and `key: "onboarding"`
- **THEN** the second call returns an `Ecto.Changeset` error on `:key` and no row is inserted.

### Requirement: Sequence Versions Capture Immutable Configuration

The system SHALL allow callers to create `dripdrop.sequence_versions` rows that pin the steps/transitions/conditions belonging to a particular `version` integer. Versions SHALL be one of `draft`, `active`, or `archived`. At most one version per sequence MAY be `active`. Activating a new version SHALL atomically demote any previously active version to `archived` in the same transaction.

#### Scenario: Create a draft version
- **WHEN** the caller calls `DripDrop.create_sequence_version(sequence_id, %{version: 1})` with no `state` argument
- **THEN** the row is inserted with `state: "draft"` and `published_at: NULL`.

#### Scenario: Activate a version
- **WHEN** the caller invokes `DripDrop.activate_sequence_version(version_id)` while a different version is currently active
- **THEN** in a single transaction the previous version's `state` becomes `"archived"`, the new version's `state` becomes `"active"`, and `published_at` is set to `NOW()`.

#### Scenario: Reject two active versions
- **WHEN** the database is asked to mark two distinct versions of the same sequence as `active`
- **THEN** the partial unique index `(sequence_id) WHERE state = 'active'` raises a constraint violation.

### Requirement: Steps Belong To A Sequence Version And Have A Channel, Timing, And Optional Adapter Override

The system SHALL store `dripdrop.steps` keyed by `(sequence_version_id, key)` with `name`, integer `position`, `channel` from the registered set (`email | sms | webhook | pubsub | slack | telegram`), an embedded `timing` configuration, a template specification (`template_type` of `inline | module | external` plus the corresponding fields), an optional `channel_adapter_id` override, free-form `config` JSONB, and an `active` flag. Step keys SHALL be unique within a sequence version.

#### Scenario: Create an immediate email step
- **WHEN** `DripDrop.create_step(version_id, %{name: "Welcome", key: "welcome", position: 1, channel: "email", timing: %{type: "immediate"}, config: %{"subject" => "Welcome", "body" => "..."}})` is called
- **THEN** the row is created with `channel: "email"`, `template_type` defaults to `"inline"`, `active: true`, and no `channel_adapter_id`.

#### Scenario: Reject step with unknown channel
- **WHEN** a caller submits `channel: "fax"`
- **THEN** the changeset returns `{:error, %Ecto.Changeset{}}` with an inclusion error on `:channel`.

#### Scenario: Reject duplicate step keys in the same version
- **WHEN** two steps with `key: "welcome"` are created against the same `sequence_version_id`
- **THEN** the unique constraint rejects the second insertion.

### Requirement: Step Transitions Express Linear And Branching Flows

The system SHALL store `dripdrop.step_transitions` rows where `from_step_id` may be `NULL` (meaning sequence entry) and `to_step_id` may be `NULL` (meaning enrollment completes). Each transition SHALL declare a `condition_mode` of `always`, `all`, or `any`, an integer `priority` (lower fires first), and free-form `config` JSONB. A sequence version with no `step_transitions` SHALL fall back to ordering by `position`.

#### Scenario: Resolve next step via transitions
- **WHEN** dispatch finishes step A and there are two transitions from A — `priority: 0, condition_mode: "all"` referencing condition X, and `priority: 1, condition_mode: "always"` to step B
- **THEN** the engine evaluates the priority-0 transition first; if X is true the engine routes to its `to_step_id`, otherwise it falls through to the priority-1 transition and routes to B.

#### Scenario: Linear ordering fallback
- **WHEN** a sequence version has steps with positions 1, 2, 3 and **no** `step_transitions` rows
- **THEN** the engine treats `position+1` as the next step and `NULL` (completion) after the last position.

#### Scenario: Explicit completion edge
- **WHEN** the engine evaluates a transition whose `to_step_id IS NULL` and whose conditions match
- **THEN** the enclosing enrollment is marked `completed`.

### Requirement: Conditions Reference Hooks, Enrollment Data, Events, Predicates, Or Time Windows

The system SHALL store `dripdrop.conditions` rows attached to either a `step_id` (gating step execution) or a `transition_id` (gating a branch). Each condition SHALL declare a `condition_type` of `hook | enrollment_data | event | predicate | time_window`, and the type-specific reference fields (`hook_function`, `http_hook_id`, `field_path`, `expected_value`, or `config`).

The `hook`, `enrollment_data`, `event`, and `time_window` types SHALL evaluate via a coercive comparator using an `operator` from `== | != | > | < | >= | <= | in | contains`. Equality and membership operators coerce both sides with `to_string/1`; the numeric operators coerce via `Float.parse/1`. Conditions whose operands cannot be coerced SHALL fail closed (evaluate to `false`) and SHALL be logged via telemetry.

The `predicate` type SHALL evaluate via the Predicated DSL stored in `config["predicate"]`. The DSL uses the same operator vocabulary as the coercive comparator and supports `and`, `or`, and parenthesised grouping. Predicate evaluation is typed: literals must match the runtime value type. Predicate parse or evaluation errors SHALL fail closed and SHALL be logged via telemetry.

#### Scenario: Hook-driven branch
- **WHEN** a transition has a single `condition_type: "hook"`, `hook_function: "setup_completed"`, `operator: "=="`, `expected_value: "false"` and the hook returns `{:ok, false}` for the enrollment
- **THEN** the condition evaluates to `true` and the transition fires.

#### Scenario: Enrollment-data JSONPath comparison
- **WHEN** a condition has `condition_type: "enrollment_data"`, `field_path: "$.plan_tier"`, `operator: "=="`, `expected_value: "enterprise"` and `enrollment.data` is `%{"plan_tier" => "enterprise"}`
- **THEN** the condition evaluates to `true`.

#### Scenario: Compound predicate with grouping
- **WHEN** a condition has `condition_type: "predicate"` and `config["predicate"]` is `"(plan == 'pro' and trial_days_remaining > 0) or has_paid_invoice == true"`
- **THEN** the predicate evaluates against the enrollment context and fires when either subexpression holds.

#### Scenario: Coercion failure fails closed
- **WHEN** an `operator: ">"` is asked to compare `"abc"` to `10`
- **THEN** the condition evaluates to `false` and emits a `[:dripdrop, :condition, :coercion_error]` telemetry event with the offending fields.

### Requirement: HTTP Hooks Are Owned By The `hooks` Capability But Are Selectable From Conditions And Templates

This capability SHALL allow `conditions` and template variable references to point at HTTP hooks via `http_hook_id`, but SHALL NOT define the storage, validation, or evaluation of `http_hooks` itself — those belong to the `hooks` capability.

#### Scenario: Reference an HTTP hook in a condition
- **WHEN** a condition is created with `http_hook_id: hook.id` referencing an existing row in `dripdrop.http_hooks`
- **THEN** the changeset succeeds and dispatch later resolves the hook through the `hooks` capability.

#### Scenario: Reject dangling hook reference
- **WHEN** a condition is created with `http_hook_id: <unknown_uuid>`
- **THEN** the foreign-key constraint rejects the insertion.

### Requirement: Authoring Validation Is Atomic Per Sequence Version

The system SHALL provide `DripDrop.validate_sequence_version(version_id)` that returns `{:ok, version}` only when (a) at least one entry transition exists or steps have positions, (b) no step references a missing channel adapter override, (c) every condition's operand and operator combination is structurally valid, (d) every cron expression parses, and (e) every referenced `hook_function` resolves on the sequence's `hook_module` or every `http_hook_id` exists. Otherwise it returns `{:error, [errors]}`.

#### Scenario: Missing entry path
- **WHEN** a version has steps but no `step_transitions` and `position IS NULL` for every step
- **THEN** validation returns `{:error, [{:no_entry_path, _}]}`.

#### Scenario: Cron expression parse failure
- **WHEN** a step's `timing.cron_expression` is `"every blursday"`
- **THEN** validation returns `{:error, [{:invalid_cron, step_key, _reason}]}`.


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
