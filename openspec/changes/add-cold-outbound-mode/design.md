## Context

DripDrop's foundation (in-flight change `add-dripdrop-foundation`) ships a flexible message-sequence engine optimized for lifecycle, transactional, and behavioral campaigns. The dispatcher already implements per-adapter and per-recipient rate limits, suppression gating, quiet-hours enforcement, RFC 8058 unsubscribe headers, bounce/complaint thresholds, and adapter rotation that is deterministic per `step_execution_id`. The foundation patch (Section 9a) closes two gaps discovered while planning this change: it wires `paused_until` enforcement into the dispatch path, adds a `recipient_domain` rate-limit scope, and clarifies that rotation re-rolls per execution by design.

What's still missing for cold outbound — sequences that target prospects with cold drip campaigns rather than known users — is a coherent set of primitives that the 2025–2026 cold-email ecosystem (Instantly, Lemlist, Smartlead, Saleshandy, Woodpecker) treat as table stakes:

1. **Enrollment-time sender pinning.** Cold drip needs the same mailbox sending every step in a sequence to a given recipient, so RFC threading (`Message-ID`/`In-Reply-To`/`References`) holds and the recipient mailbox-provider's per-`(sender, recipient)` engagement history accumulates correctly. Lifecycle's per-execution re-roll is wrong for cold and right for cold-vs-lifecycle generalization.
2. **Adapter pools.** Sequences need to nominate a set of equivalent senders and rotate fresh enrollments across them weighted by health and capacity.
3. **Adapter health state machine.** The foundation's `paused_until` is a single signal. Cold needs a four-state lifecycle (`active → resting → probing → ramping`) with auto-recovery, exponential backoff on repeat breaches, and a probe phase that verifies recovery before returning to full capacity.
4. **Ramp-up curves.** New mailboxes need a daily-cap floor that climbs over the first 2–4 weeks; provider reputation algorithms reward graduated reputation building.
5. **Per-(adapter, sequence) sub-caps.** Blast-radius protection so a buggy or runaway sequence cannot burn an entire mailbox's daily headroom.
6. **Min-gap-between-sends per adapter** (cross-sequence). Provider abuse heuristics flag sub-minute volume spikes; this is a separate constraint from daily-cap-per-day.
7. **Outbound RFC `Message-ID` storage and threading.** The foundation stores `provider_message_id` (the provider's internal id) but doesn't generate or persist the RFC 5322 `Message-ID`, and outbound emails don't carry `In-Reply-To`/`References` on follow-up sends.
8. **Host-callable inbound message ingestion.** Today's reply correlation requires a webhook (Mailgun/SendGrid/Postmark inbound parse). Hosts pumping replies from IMAP, Microsoft Graph subscriptions, or Gmail API watches have no entry point.

The user's hard constraint: **DripDrop must remain flexible for any messaging campaign type — both current lifecycle/transactional AND cold drip.** No design choice in this change should make lifecycle worse to accommodate cold. The strategy is purely additive: a new `:outbound` mode flag flips on the new gates, and lifecycle dispatch continues unchanged when the flag is off.

A second-opinion consult with Codex (preserved in the planning thread) shaped the column-vs-table, mode-placement, threading-storage, and ETS-vs-persisted-state decisions documented below.

## Goals / Non-Goals

**Goals:**

- Add a `:outbound` mode to sequence versions that turns on enrollment-time pinning, ramp-aware daily caps, sub-caps, min-gap, and threading-header stamping without changing any lifecycle behavior.
- Introduce adapter pools as a first-class entity so sequences can nominate a weighted set of equivalent senders and have the dispatcher rotate fresh enrollments across them.
- Generalize the foundation's `paused_until` signal into a four-state health machine (`active → resting → probing → ramping`) with auto-recovery and exponential backoff.
- Add ramp-up curves per adapter as DB-level configurable linear progressions (`ramp_started_at`, `ramp_increment`, `ramp_floor`, `daily_cap`).
- Add per-(adapter, sequence_version) sub-caps for blast-radius protection.
- Add per-adapter min-gap-between-sends as a cross-sequence constraint.
- Add outbound RFC `Message-ID` generation and `In-Reply-To`/`References` stamping on email follow-up sends in outbound mode.
- Add host-callable `DripDrop.ingest_inbound_message/2` for IMAP/Graph/Gmail-fed replies, correlating against `out_message_id` (preferred) or `provider_message_id` (fallback).
- Add an optional spintax / variable-pack rendering layer with deterministic per-execution seeding.
- Preserve all foundation-defined behavior: same FSM, same rotation semantics, same selection chain for lifecycle, same suppression model, same quiet-hours and rate-limit logic.

**Non-Goals:**

- **Warmup networks.** Reciprocal-engagement graphs (the AI warmup pools that Mailwarm, Warmup Inbox, Instantly's pool, lemwarm operate) are explicitly out of scope. Hosts that need warmup integrate a third-party service externally; DripDrop will not run a warmup network.
- **IMAP / Microsoft Graph / Gmail API polling.** DripDrop will not ship an inbound mail poller or maintain Graph subscriptions. Hosts wire their own inbound source and call `DripDrop.ingest_inbound_message/2`. This keeps the library out of OAuth-refresh, IMAP-state-management, and provider-API-rate-limit territory that hosts often already handle.
- **OAuth flows for inbound mail authentication.** Inherits the foundation's posture: host owns OAuth.
- **Postmaster Tools / GlockApps / seed-test integration.** Hosts can feed external health signals to `DripDrop.set_adapter_health/2` if they integrate with one; DripDrop ships no built-in poller.
- **AI-generated first-line personalization.** Hosts can pre-render via the existing template variable pipeline; spintax provides structural variation but not LLM-generated content.
- **List verification (Zerobounce / NeverBounce / Kickbox).** Host concern.
- **Warmup-vs-campaign send-volume separation.** Since no warmup ships here, the question doesn't arise. The daily cap counts all real outbound sends.
- **Cross-tenant pool sharing.** Pools are tenant-scoped; sharing a mailbox pool across tenants couples reputation in dangerous ways. Pool tenant_key follows the existing tenant model — `NULL` only for global single-tenant deployments.

## Decisions

### D1. `:mode` lives on `sequence_version`, not `sequence` or `enrollment`

**Decision:** Add a `mode` column to `sequence_versions` with values `lifecycle | outbound`, default `lifecycle`. Snapshot the effective mode onto `enrollments.effective_mode` at enrollment creation time so mid-flight version flips don't disturb in-progress enrollments.

**Rationale:** Sequence versions already model draft/active/archived states; mode-per-version aligns with that lifecycle and lets a sequence transition between modes through normal version activation. Per-sequence (one mode for life) is too rigid and makes it hard to A/B test or migrate. Per-enrollment is too granular and creates ambiguous semantics when an active sequence has both modes' enrollments mid-flight.

**Alternatives considered:**
- *Mode on `sequence`:* simpler but inflexible and not aligned with versioning.
- *Inferred mode from pool presence:* implicit, fragile, and makes lifecycle-with-pool (a future possibility) harder.

### D2. Pools coexist with `is_default`; no unification

**Decision:** Lifecycle adapter selection continues to use `is_default` and the existing `select/3` chain (`step.channel_adapter_id` → step rotation → sequence rotation → tenant default → global default). Outbound mode bypasses that chain and resolves through `sequence_version.config["pool_id"] → pool member → enrollment pin`. There is no "implicit pool of one" abstraction unifying the two.

**Rationale:** Codex flagged the unification path as unnecessary cross-cutting churn. Strict separation by mode is the safest additive move — lifecycle dispatch is byte-identical to today; outbound gets pool semantics; nothing in between. Future work can unify if it ever becomes necessary, but the cost of touching the existing selection chain now exceeds the elegance benefit.

**Alternatives considered:**
- *Pools fully replace `is_default` for outbound:* what we picked.
- *Pools generalize `is_default` (default = pool of one):* elegant in theory, breaks too much existing code in practice.

### D3. Health state machine columns on `channel_adapters`, not a separate table

**Decision:** Add `health_state`, `health_score`, `resting_until`, `last_send_at`, `daily_cap`, `ramp_started_at`, `ramp_increment`, `ramp_floor`, `min_gap_seconds` as nullable columns on `channel_adapters`. Lifecycle adapters leave them null; the dispatcher's outbound-mode gates short-circuit when columns are unset.

**Rationale:** Dispatch is a hot path. Adding a join against an `adapter_health` table for every candidate adapter selection costs at minimum a row-level lookup per dispatch tick. Nullable columns are cheap and free for lifecycle (which never reads them). The `channel_adapters` row count will always be small (10s–100s), so wide-table concerns don't apply.

**Alternatives considered:**
- *Separate `adapter_health` table:* cleaner separation but unnecessary I/O and code complexity.
- *All knobs in `config` JSONB:* matches today's `paused_until` storage but is hard to query, hard to validate, and gives operators no schema-level guarantees.

### D4. WDRR deficit counters in ETS only, not persisted

**Decision:** The Weighted Deficit Round Robin allocator that distributes fresh enrollments across pool members tracks per-(pool_member, sequence_version) deficit counters in ETS. Restart resets the counters to zero (fair-share continues, just without prior history).

**Rationale:** At 30–200 sends/day per adapter and rare restart frequency, persisting deficit counters costs a DB write on every dispatch tick for negligible fairness gain. ETS gives microsecond-latency reads and writes. Document explicitly that strict cross-restart fairness continuity is a non-goal; the reset behavior is conservative (no member is favored after restart).

**Alternatives considered:**
- *Persisted counters in `adapter_sequence_budgets`:* costs hot-path I/O, gains nothing observable.
- *Hybrid (ETS fast path with periodic flush):* premature optimization, adds complexity without clear benefit.

### D5. Linear ramp columns, not curve JSONB

**Decision:** `daily_cap`, `ramp_started_at`, `ramp_increment`, `ramp_floor` as integer/timestamp columns. `effective_cap_today(adapter) = min(daily_cap, ramp_floor + days_since_start * ramp_increment)`.

**Rationale:** The user wanted DB-level configurability. Linear ramps cover every documented public ramp curve (lemwarm's +1/day or +2/day, Mailgun's percentage growth simplified to linear, Instantly's gradual increase). Curve JSONB is premature flexibility that complicates validation, makes operator UIs harder, and isn't necessary for the documented use case.

**Alternatives considered:**
- *Named `ramp_profile_id` referencing a JSONB curve:* flexible but premature.
- *Hard-coded global ramp:* not enough flexibility.

### D6. Threading metadata: outbound `Message-ID` on `step_executions`, inbound headers on `message_events`

**Decision:**
- New `step_executions.out_message_id text` column for the RFC 5322 `Message-ID` we generate and stamp into outbound headers. Distinct from `provider_message_id` (the provider's internal id).
- New `message_events.in_reply_to text` and `message_events.references_list jsonb` columns capturing inbound RFC headers.
- Email channel adapters in outbound mode generate `out_message_id` per send, stamp it as the `Message-ID:` header, and on follow-up steps stamp `In-Reply-To: <previous_step.out_message_id>` and `References:` chain.

**Rationale:** Codex flagged that conflating `provider_message_id` with `Message-ID` is wrong — they're different identifiers with different lifetimes and uniqueness scopes. Storing them separately is the correct hygiene. Inbound headers belong on `message_events` (the per-event record), not `step_executions` (the per-outbound-attempt record), because inbound events are per-event by nature. A separate `email_threads` table is overkill at this stage; threads can be reconstructed via JOIN.

**Alternatives considered:**
- *Overload `provider_message_id` for both:* incorrect data modeling, breaks at archive time.
- *New `email_threads` join table:* unnecessary for the documented use case.
- *Inbound headers on `step_executions`:* pollutes the outbound-only table.

### D7. Daily cap layered: keep `sender_mailbox` primary, add `adapter_id` parallel

**Decision:** The existing daily-cap implementation in `Policy.SendingRules` keys on `sender_mailbox` (extracted from the `from` header) and stays as-is. Outbound mode adds a parallel check keyed on `adapter_id` against an extended `event_data->>'adapter_id'` query path. The stricter constraint wins.

**Rationale:** For OAuth pools (Gmail/M365), one adapter ≈ one mailbox, so `sender_mailbox` keying is effectively per-adapter. For ESP-API adapters where many `from` addresses share one credential, `sender_mailbox` keying alone misses "this Mailgun account total daily" caps. Parallel keying is additive — lifecycle behavior is preserved exactly. Migrating primary keying would risk subtle lifecycle regressions.

**Alternatives considered:**
- *Migrate primary keying to `adapter_id`:* risks breaking existing lifecycle daily-cap users.
- *Composite `(adapter_id, sender_mailbox)` keying:* doesn't compose well with config inheritance.

### D8. No FSM changes; outbound gates short-circuit through existing states

**Decision:** The `step_executions.state` FSM (`scheduled → claiming → sending → sent | failed | skipped | cancelled`) is unchanged. New outbound-mode gates that block dispatch (ramp cap hit, sub-cap exhausted, min-gap violated, pool exhausted) defer through the existing `claiming → scheduled` transition with `scheduled_for` set forward, exactly like the foundation's existing rate-limit and quiet-hours gates.

**Rationale:** Codex specifically flagged FSM changes as a lifecycle-flexibility risk. Adding cold-only states (`:resting_at_dispatch`, `:pool_exhausted`, etc.) would force lifecycle code paths to handle them, breaking the additivity invariant. The existing `defer` → `reschedule` → `enqueue` machinery handles every new gate cleanly without new states.

**Alternatives considered:**
- *New `pool_exhausted` and `min_gap_held` states:* more visible but breaks lifecycle.
- *Persistent in-flight-deferred queue separate from `step_executions`:* unnecessary complexity.

### D9. Inbound ingestion is host-callable, not a built-in poller

**Decision:** `DripDrop.ingest_inbound_message/2` accepts a `(adapter_id_or_tenant_key, normalized_message_map)` signature. The map carries `from`, `to`, `subject`, `body_text`, `body_html`, `message_id`, `in_reply_to`, `references`, `received_at`, `headers` (raw passthrough), and optional `intent` (host-classified `:reply | :ooo | :auto_reply` + optional `return_at`). DripDrop correlates against stored `out_message_id` (preferred) or falls back to `provider_message_id`. Routes to the configured `OnReply` callback identically to the webhook path.

**Rationale:** IMAP, Microsoft Graph subscriptions, Gmail API watches each have their own auth flows, rate limits, polling cadences, and failure modes. Hosts that need cold outbound generally already have inbox infrastructure for their own product features. Reinventing it inside the library would force OAuth-refresh logic, IMAP IDLE management, Graph subscription renewal, etc. — none of which is DripDrop's core competency. The thin ingestion API keeps the library clean.

**Alternatives considered:**
- *Built-in IMAP poller as an opt-in dep:* adds significant maintenance burden and OAuth complexity.
- *Webhook-only (no host-callable API):* leaves Gmail/M365 OAuth-mailbox replies undetectable since those providers don't push delivery webhooks for inbound mail in the same way ESPs do.

### D10. Lifecycle non-regression is the primary correctness invariant

**Decision:** Every test in the foundation's lifecycle test suite (Section 14a integration tests, plus all per-capability scenario tests) MUST continue to pass byte-identically after this change lands. New outbound tests run in addition, never replacing or modifying lifecycle assertions. CI runs the lifecycle suite both with the new schema (`V02` migration applied) and against any sequence with `mode = lifecycle`, asserting no behavioral drift.

**Rationale:** The user's hard constraint. Without this invariant, "outbound mode is purely additive" is unverifiable.

## Risks / Trade-offs

- **WDRR fairness reset on restart** → Mitigation: documented as a non-goal for strict continuity. At expected volumes (30–200 sends/day per adapter) the reset converges within minutes of normal traffic. Operators who care can monitor `[:dripdrop, :dispatch, :pool_pick]` telemetry to verify distribution.
- **Mixed-class pools (OAuth mailboxes + ESP API adapters in one pool) have different cap math** → Mitigation: pools have a `class` discriminator on members; the dispatcher's pool-pick logic groups by class and applies class-specific cap math (mailbox class uses `sender_mailbox` cap + min-gap; ESP class uses `adapter_id` cap + per-second rate). Default to single-class pools in documentation; mixed-class is supported but flagged as advanced.
- **Lifecycle regression risk from new dispatch gates** → Mitigation: every new gate has a `mode == :outbound` guard at its entry. Lifecycle code path is unchanged. Test invariant D10 enforces this.
- **`out_message_id` collision risk** → Mitigation: generate as `${uuidv7()}@${sending_domain}` per RFC 5322. UUIDv7 is collision-free at human scale; sending domain is operator-controlled.
- **Reply correlation false-positives** → Mitigation: prefer `out_message_id` matching (RFC-aligned, recipient mail clients reliably copy it into `In-Reply-To`); fall back to `provider_message_id` only when the inbound source explicitly provides it. Telemetry on unmatched events surfaces drift early.
- **Spintax determinism vs. variation goal** → Mitigation: deterministic per `(step_execution_id, attempt_window)` so retries render identically (idempotency invariant). Cross-recipient variation comes from different `step_execution_id`s producing different seeds; the cardinality of templates per sequence is the operator's responsibility.
- **Per-(adapter, sequence) sub-cap requires a join in dispatch hot path** → Mitigation: the join is on indexed columns and the sub-cap row count is always small (one row per active outbound sequence × adapter membership). Profiling pre-merge will confirm cost is negligible.
- **Pool-exhausted means enrollment pause; if the host doesn't notice, sequences stall** → Mitigation: emit `[:dripdrop, :dispatch, :pool_exhausted]` telemetry with `pool_id`, `sequence_version_id`, and the list of evicted adapter ids. Document this in operator-runbook.

## Migration Plan

- **Schema:** new EctoEvolver version `V02` adds `adapter_pools`, `adapter_pool_members`, `adapter_sequence_budgets` tables and the new columns on `channel_adapters`, `enrollments`, `sequence_versions`, `steps`, `step_executions`, `message_events`. All new columns are nullable. No backfill required.
- **Existing data:** untouched. Existing sequences default to `mode = lifecycle`. Existing enrollments leave `effective_mode NULL` which the dispatcher treats as `:lifecycle`. Existing channel adapters leave health/ramp columns null and skip the new gates.
- **Rollback:** drop the three new tables; drop the new columns. Lifecycle behavior remains identical. The `V02` migration's down step does this.
- **Foundation patches:** the `add-dripdrop-foundation` change ships its 9a Section patches in `V01`. This change builds on those without modifying them. `V02` only adds; never alters `V01`-introduced columns.
- **Public API:** all new functions are additive on the `DripDrop.*` module. No existing function signatures change.
- **Test strategy:** new outbound integration tests run alongside the lifecycle suite. CI fails if any lifecycle test changes behavior.

## Open Questions

- **Q1.** Should `DripDrop.ingest_inbound_message/2` require HMAC-style host-supplied auth (akin to the webhook plug's signature verification), or trust the host's call boundary? Lean toward trust-by-default since the host is in-process; expose an optional `verify_signature` callback for hosts that pump from untrusted networks.
- **Q2.** Should spintax be a `step.template_type = :spintax` value, or a global rendering option layered on top of any existing template type? Lean toward layer-on-top so spintax can wrap Liquex output, MJML output, and EEx output without separate engines.
- **Q3.** Pool member `class` discriminator — do we ship the three values now (`mailbox_oauth_smtp | esp_api | smtp_relay`) or start with two (`mailbox | esp_api`) and split later? Lean toward two; SMTP relays are functionally a subset of mailbox class for cap math purposes.
- **Q4.** Should `DripDrop.set_adapter_health/2` accept arbitrary external signals (Postmaster Tools score, GlockApps inbox-placement, host-defined metrics) or only the structured set DripDrop's state machine consumes? Lean toward structured intake (`%{spam_complaint_rate: f, bounce_rate: f, inbox_placement: f, source: atom}`) with rejection of unknown keys for now.
- **Q5.** Documentation: should we add a new top-level `guides/cold_outbound.md` covering pool authoring, ramp planning, threading verification, and the inbound-pumping integration pattern? Strong yes — but is implementation-side, captured in tasks.
