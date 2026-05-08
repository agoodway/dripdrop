## ADDED Requirements

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
