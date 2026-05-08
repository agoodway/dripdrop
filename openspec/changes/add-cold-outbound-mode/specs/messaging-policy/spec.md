## ADDED Requirements

### Requirement: Per-(Adapter, Sequence-Version) Sub-Cap Provides Blast-Radius Protection

The system SHALL persist `dripdrop.adapter_sequence_budgets` rows with `adapter_id`, `sequence_version_id`, `weight` (integer, default 1), `max_share_pct` (integer in `[1, 100]`, default 100), `daily_volume_target` (integer, nullable), `inserted_at`, `updated_at`. For outbound-mode enrollments, before sending the system SHALL compute the sequence's allocated share of the adapter's effective daily cap as `floor(effective_cap_today(adapter) * max_share_pct / 100)`, then count today's sends from this adapter for this sequence-version, and defer when the share is exhausted. The constraint applies in addition to (and is bounded by) the adapter-level daily cap.

#### Scenario: Sub-cap prevents one sequence from burning all headroom
- **WHEN** adapter `gmail_a` has `effective_cap_today = 30`, sequence A has `max_share_pct = 50`, sequence B has `max_share_pct = 50`, both share `gmail_a`, and sequence A has already sent 15 today
- **THEN** sequence A's next send defers (it has reached its 50% sub-cap of 15), but sequence B can still send up to 15 of its own.

#### Scenario: Default 100% sub-cap behaves as no-op
- **WHEN** an adapter-sequence budget defaults to `max_share_pct = 100` and `weight = 1`
- **THEN** the sub-cap gate evaluates to "no constraint beyond the adapter cap" and dispatch proceeds without sub-cap-driven deferral.

#### Scenario: Sub-cap deferral emits telemetry
- **WHEN** a sub-cap defers an execution
- **THEN** `[:dripdrop, :policy, :sub_cap]` telemetry fires with `adapter_id`, `sequence_version_id`, `share_count`, `share_cap`, `defer_until`.

### Requirement: Daily Cap Adds Adapter-ID Keying As A Parallel Constraint For Outbound

For outbound-mode enrollments, the system SHALL enforce a daily cap keyed on `adapter_id` in addition to the foundation's `sender_mailbox`-keyed daily cap. The query path SHALL count `message_events` where `event_type = 'sent' AND event_data->>'adapter_id' = $adapter_id` over the day boundary in the configured timezone. The stricter of (sender-mailbox cap, adapter-id cap, ramp-effective cap, sub-cap share) SHALL win on each dispatch attempt. Lifecycle dispatch SHALL continue to use only the `sender_mailbox`-keyed cap (foundation behavior preserved).

#### Scenario: Adapter-id cap catches ESP-API account-level exhaustion
- **WHEN** an outbound enrollment's pinned adapter is a Mailgun account with `daily_cap = 1000`, the account has sent 1000 emails today across many `from` addresses, and a new send attempts
- **THEN** the adapter-id cap is exhausted (regardless of `sender_mailbox` cap state), the execution defers, and `[:dripdrop, :policy, :daily_cap]` telemetry fires with `keying: :adapter_id`.

#### Scenario: OAuth-mailbox cap matches across keying paths
- **WHEN** an outbound enrollment's pinned adapter is a Gmail OAuth mailbox where adapter ≈ mailbox 1:1
- **THEN** the `sender_mailbox` cap and `adapter_id` cap converge on the same count; either path defers correctly when 30 sends have occurred against `daily_cap = 30`.

### Requirement: Min-Gap-Between-Sends Enforces Cross-Sequence Spacing

The system SHALL implement `DripDrop.Policy.MinGap.check/2` that runs in the dispatch path between concurrency check and rate-limit check. The check SHALL refuse to dispatch when `now() - adapter.last_send_at < adapter.min_gap_seconds`, deferring with `scheduled_for = adapter.last_send_at + min_gap_seconds`. The `last_send_at` value is updated atomically with the `state → "sent"` transition (already specified in the `channel-adapters` capability). The constraint applies across all sequences using the adapter, not per-sequence.

#### Scenario: Min-gap enforced across two sequences
- **WHEN** adapter `gmail_a` has `min_gap_seconds = 90`, sequence A sent at 10:00:00, sequence B attempts to send at 10:00:30
- **THEN** sequence B defers to 10:01:30, emits `[:dripdrop, :policy, :min_gap]`, and does NOT call the channel adapter.

#### Scenario: Adapters without min_gap configured skip the gate
- **WHEN** an adapter has `min_gap_seconds IS NULL`
- **THEN** the min-gap gate short-circuits and dispatch proceeds through the next gate.

### Requirement: Adapter Health State Engages The Resting Cooldown In The Dispatch Path

For outbound-mode enrollments, before any send the system SHALL check the pinned adapter's `health_state` and `resting_until`. When `health_state == "resting"` and `resting_until > now()`, dispatch SHALL defer the execution with `scheduled_for = resting_until` (or `pool.on_pin_unavailable` policy when `resting_until` is far enough in the future to warrant pause/reassign — see `dispatch-execution` capability). The check SHALL run BEFORE all other outbound-only gates so a resting adapter doesn't waste cycles on subsequent gate evaluation.

#### Scenario: Resting adapter defers to recovery time
- **WHEN** an outbound enrollment's pinned adapter has `health_state = "resting", resting_until = now() + 4 hours`
- **THEN** dispatch defers with `scheduled_for = resting_until`, emits `[:dripdrop, :policy, :adapter_resting]` with `health_state, resting_until, adapter_id`, and skips the remaining outbound gates.

#### Scenario: Probing adapter passes the health gate but uses probe cap
- **WHEN** an outbound enrollment's pinned adapter has `health_state = "probing"`
- **THEN** the health gate allows dispatch (probing is an active sending state), but the ramp cap gate uses the configured probe-phase budget instead of the linear ramp formula (per the `channel-adapters` capability).
