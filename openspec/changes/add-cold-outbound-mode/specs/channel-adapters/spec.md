## ADDED Requirements

### Requirement: Channel Adapters Carry Optional Health State And Ramp Configuration Columns

The system SHALL extend `dripdrop.channel_adapters` with the following nullable columns: `health_state` (text, one of `active | resting | probing | ramping`, default `NULL`), `health_score` (numeric in `[0, 1]`, default `NULL`), `resting_until` (timestamptz, default `NULL`), `last_send_at` (timestamptz, default `NULL`), `daily_cap` (integer, CHECK > 0, default `NULL`), `ramp_started_at` (timestamptz, default `NULL`), `ramp_increment` (integer, CHECK > 0, default `NULL`), `ramp_floor` (integer, CHECK >= 0, default `NULL`), `min_gap_seconds` (integer, CHECK >= 0, default `NULL`). Adapters that leave these columns NULL SHALL behave identically to today (lifecycle dispatch path is unchanged). Outbound-mode dispatch gates SHALL short-circuit (treat as "no constraint") when their corresponding column is NULL.

#### Scenario: Lifecycle adapter ignores new columns
- **WHEN** a channel adapter has all new columns NULL (the default for adapters created without specifying outbound config)
- **THEN** dispatch routes through the existing selection chain, no health/ramp/min-gap gates fire, and behavior is byte-identical to the foundation specification.

#### Scenario: Outbound adapter populates all columns
- **WHEN** an operator creates an adapter with `daily_cap: 30, ramp_started_at: now(), ramp_increment: 2, ramp_floor: 5, min_gap_seconds: 90, health_state: "ramping"`
- **THEN** the row is inserted, the dispatcher reads these columns when this adapter is selected for an outbound-mode enrollment, and the corresponding gates engage.

### Requirement: Adapter Health State Machine Has Four States With Documented Transitions

The system SHALL implement a state machine over `health_state` with allowed transitions: `NULL → active`, `NULL → ramping`, `active → resting`, `ramping → active`, `ramping → resting`, `resting → probing`, `probing → ramping`, `probing → resting`, `active → NULL` (operator manual reset). Transitions SHALL be triggered by: (a) `BounceComplaintThresholds` GenServer breaches → `→ resting` with `resting_until = now() + cooldown`; (b) automatic recovery when `resting_until` passes → `resting → probing` on the next dispatch attempt; (c) probe-phase success (no breach in 24h with at least N sends) → `probing → ramping`; (d) probe-phase failure → `probing → resting` with exponential backoff applied to next cooldown. Manual transitions via `DripDrop.set_adapter_health/2` SHALL be permitted from any state to any state with audit-event logging.

#### Scenario: Threshold breach moves adapter to resting
- **WHEN** the `BounceComplaintThresholds` checker detects `bounce_rate >= 0.02` for an adapter
- **THEN** the adapter transitions to `health_state = "resting"`, `resting_until = now() + 24h` (default cooldown), `[:dripdrop, :health, :state_changed]` telemetry fires with `from: "active", to: "resting", reason: "bounce_threshold"`, and the dispatcher excludes the adapter from pool selection until `resting_until` passes.

#### Scenario: Probe phase verifies recovery
- **WHEN** an adapter's `resting_until` has passed and a new outbound dispatch attempts to use the pool
- **THEN** the adapter transitions to `probing`, the dispatcher allows up to a configurable probe budget (default 5 sends per 24h), and on completion of the probe window without threshold breach the adapter transitions to `ramping` with `ramp_started_at = now()`.

#### Scenario: Repeat breach applies exponential backoff
- **WHEN** an adapter that recently exited `resting` (within 7 days) breaches threshold again
- **THEN** the next `resting_until` cooldown is doubled from the prior cooldown (24h → 48h → 7d, capped); telemetry includes `breach_count` and `cooldown_seconds`.

### Requirement: Ramp-Up Cap Is Applied As Linear Function Of Days Since Ramp Start

For adapters with `ramp_started_at`, `ramp_increment`, and `ramp_floor` populated, the system SHALL compute the effective daily cap as `effective_cap_today(adapter) = min(adapter.daily_cap, ramp_floor + days_elapsed * ramp_increment)` where `days_elapsed = max(0, floor((now() - ramp_started_at) / 1 day))`. Adapters in `health_state = "probing"` SHALL use a fixed probe-phase cap (default 5/day) instead of the ramp formula. Adapters with no ramp configuration (NULL ramp columns) SHALL use `daily_cap` directly when set, or no daily cap at all when both `daily_cap` and ramp columns are NULL.

#### Scenario: Linear ramp climbs to daily_cap over time
- **WHEN** an adapter has `daily_cap: 50, ramp_started_at: now() - 10 days, ramp_increment: 2, ramp_floor: 5`
- **THEN** `effective_cap_today = min(50, 5 + 10 * 2) = min(50, 25) = 25`.

#### Scenario: Mature adapter caps at daily_cap ceiling
- **WHEN** an adapter has `daily_cap: 50, ramp_started_at: now() - 30 days, ramp_increment: 2, ramp_floor: 5`
- **THEN** `effective_cap_today = min(50, 5 + 30 * 2) = min(50, 65) = 50`.

#### Scenario: Probing adapter uses fixed probe cap
- **WHEN** an adapter has `health_state = "probing"` regardless of ramp configuration
- **THEN** the effective cap for the probe day is the configured probe budget (default 5), and ramp resumes when `probing → ramping` transition occurs.

### Requirement: Min-Gap-Between-Sends Is A Cross-Sequence Per-Adapter Constraint

For adapters with `min_gap_seconds` populated, the system SHALL refuse to dispatch a new send when `now() - last_send_at < min_gap_seconds`, deferring the execution by transitioning back to `scheduled` with `scheduled_for = last_send_at + min_gap_seconds`. The constraint SHALL apply across all sequences using the adapter (not per-sequence). The `last_send_at` column SHALL be updated atomically with `step_execution.state = "sent"` transition.

#### Scenario: Min-gap respected across sequences
- **WHEN** adapter `gmail_a` has `min_gap_seconds: 90` and was last used at 10:00:00 by sequence A; sequence B attempts to dispatch through `gmail_a` at 10:00:30
- **THEN** sequence B's execution defers to 10:01:30, emits `[:dripdrop, :policy, :min_gap]` telemetry with `gap_remaining_seconds: 60`, and does NOT call the channel adapter.

#### Scenario: Lifecycle adapter without min_gap dispatches normally
- **WHEN** adapter `mailgun_a` has `min_gap_seconds = NULL` (lifecycle default)
- **THEN** the min-gap gate short-circuits and dispatch proceeds without deferral, regardless of how recently the adapter was used.

### Requirement: Outbound Adapter Selection Bypasses The Existing `is_default` Chain

When the dispatcher resolves an adapter for a step whose enclosing enrollment has `effective_mode == "outbound"`, the system SHALL: (a) read `enrollments.adapter_id`; (b) verify the adapter is still active and not in terminal `resting` state; (c) use that adapter directly. The `step.channel_adapter_id → step rotation → sequence rotation → tenant default → global default` chain from the foundation specification SHALL NOT execute for outbound-mode enrollments. Lifecycle (`effective_mode IS NULL` or `effective_mode == "lifecycle"`) enrollments continue to use the existing chain unchanged.

#### Scenario: Outbound enrollment uses pinned adapter for every step
- **WHEN** an outbound enrollment with `adapter_id: gmail_a.id` dispatches step 1, step 2, and step 3
- **THEN** all three executions resolve to `gmail_a` and the existing rotation/default chain is bypassed.

#### Scenario: Lifecycle enrollment unaffected by outbound selection logic
- **WHEN** a lifecycle enrollment (no `effective_mode` set) dispatches a step
- **THEN** the foundation's `step → step rotation → sequence rotation → tenant default → global default` chain executes exactly as documented, with no outbound-mode side effects.
