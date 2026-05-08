## Context

The DripDrop foundation change defined the library and originally declared a `demo-app` capability covering a Phoenix LiveView reference application at `demo/`. As foundation neared completion, the demo's scope (~15 implementation tasks plus a manual deliverability smoke and ~3 release-time entanglements) became the dominant remaining-work cost on a foundation that was otherwise feature-complete.

Pulling the demo into its own change unblocks foundation's `v0.1.0` archive, isolates the Phoenix-app churn from the library's own release cadence, and makes the demo's quality gates independently runnable (rather than coupled to library CI).

The library's existing `Dockerfile`, `docker-compose.yml`, and `mix.exs` `package:` exclusion of `demo/` were authored by foundation tasks 1.2 / 1.7 / 1.8 and are already complete. This change does not duplicate them; the demo simply uses them.

## Goals / Non-Goals

**Goals:**

- Move the `demo-app` capability cleanly out of `add-dripdrop-foundation` and into this change, with no behavioral change to the library.
- Ship a `demo/` Phoenix 1.8 + LiveView 1.1 application that boots against the local library, runs three scenario LiveViews matching the README examples, exposes a read-only dashboard, ships idempotent seeds, and documents the run loop in its own README.
- Validate the foundation public API end-to-end through the demo (any gap discovered becomes a foundation-side fix rather than a demo workaround).
- Define a demo-side `mix quality` alias so demo CI is clean.
- Provide a manual deliverability smoke recipe via the demo for release validation.

**Non-Goals:**

- **Outbound-mode demo scenario.** A 4th `OutboundLive` scenario showcasing cold-drip pools, ramps, threading, and reply detection is deferred to a follow-on change after both this change and `add-cold-outbound-mode` are archived. Cold-outbound's `tasks.md` task 15.5 is updated to reference this change instead of foundation.
- **Editable dashboard.** Sequence editing, adapter management, hook testing UI, etc. are deferred to a future `add-dripdrop-dashboard` change. The demo's read-only dashboard is the placeholder.
- **Production deployment.** The demo is a local-development reference. Hosting, auth, multi-tenant separation, and rate-limiting the demo itself are out of scope.
- **Library code changes.** This change MUST NOT modify `lib/dripdrop/**`, `priv/dripdrop/**`, or the library's `mix.exs`. If demo implementation reveals a library bug, it gets fixed in foundation (or a follow-on library change), not by working around it in the demo.
- **Top-level `Dockerfile` / `docker-compose.yml` ownership.** Already foundation work; this change uses but does not respec them.

## Decisions

### D1. Demo lives at `demo/`, mirrors the pgflow pattern, uses foundation's existing repo-root Docker setup

**Decision:** `demo/` is a sibling Phoenix 1.8 + LiveView 1.1 app with `{:dripdrop, path: ".."}`. The repo root carries the `Dockerfile` (Postgres 18 + pg_cron preloaded) and `docker-compose.yml` shipped by foundation; the demo just uses them.

**Rationale:** Path-dep means the demo always builds against the working copy of the library — surface gaps and breakages show up immediately, not after a Hex publish. One Phoenix app (vs. three sibling apps per scenario) means one Postgres image, one CI matrix, one set of seeds, and one place to wire the dispatch worker, ingest plug, and dashboard side-by-side. **Trade-off:** the demo can drift toward kitchen-sink. Mitigation — every scenario lives in its own `lib/dripdrop_demo_web/live/scenarios/<name>/` module with no shared business logic, and `mix demo.seed` is the only sanctioned way to load fixtures.

This decision is lifted essentially verbatim from foundation's prior D18, retained here because the rationale is unchanged and ownership has moved.

### D2. Read-only dashboard now, editable dashboard deferred

**Decision:** The demo ships read-only LiveViews under `/dashboard/*` (`SequencesLive`, `EnrollmentsLive`, `ExecutionsLive`, `EventsLive`). No forms, no buttons, no mutating endpoints exposed under `/dashboard/*`.

**Rationale:** Operators need visibility into what the library is doing in their fixture data — read-only LiveViews give 80% of the value at 5% of the surface area. The full editable dashboard requires authentication, authorization, audit logging, and a richer state-management story; deferring it keeps this change small and unblocks the demo. **Migration path:** the read-only views can be promoted into a router macro and extended with editing actions when `add-dripdrop-dashboard` lands.

### D3. Mock HTTP-hook server lives in the demo, NOT in the library

**Decision:** The LeadNurtureLive scenario calls a Bypass-style HTTP hook. The mock server (`demo/lib/dripdrop_demo/mock_hooks.ex`) is part of the demo app — it boots when the demo Phoenix app boots and exposes a deterministic in-process URL.

**Rationale:** The library's own integration test (foundation task 14a.1) was previously phrased as *"using the demo's mock-hooks endpoint."* That cross-dependency is now removed: foundation's 14a.1 has been refactored to use a `test/support` Bypass stub instead. Result: foundation's library tests don't depend on the demo, and the demo's mock_hooks lives where it's actually used. **Trade-off:** two slightly different mock implementations. Mitigation — both are tiny (~30 lines of Bypass each) and both deterministic; divergence is unlikely.

### D4. `demo/mix.exs` defines its own `quality` alias

**Decision:** The demo's `mix.exs` defines `quality` as an alias running `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`. This mirrors the library's alias verbatim (with adjustments for Phoenix-specific surfaces, e.g., the demo's HEEx files trip `sobelow` differently than library Elixir files).

**Rationale:** Foundation task 15.2 noted *"Demo-app quality is paused while the Phoenix demo is removed from scope"* — that pause becomes permanent at the library level once foundation archives, but the demo needs its own quality gate. Defining the alias inside `demo/mix.exs` (rather than the root `mix.exs`) keeps demo CI runnable from `cd demo && mix quality` and prevents the library's CI from blocking on demo-only quality issues.

### D5. Demo deliverability smoke is owned by this change, not foundation

**Decision:** The manual deliverability smoke recipe (real Mailgun sandbox, 25 messages, verify SPF/DKIM/DMARC pass, RFC 8058 round-trip) is documented in `demo/README.md` and tracked as a release task in this change's `tasks.md`.

**Rationale:** Without the demo, foundation has no obvious place to run a 25-message live test. The smoke depends on the demo existing. Moving it here is the natural seam.

### D6. Idempotent seeds with `Ecto.Multi.upsert/4` semantics on stable keys

**Decision:** `mix demo.seed` uses upsert semantics keyed on `(tenant_key, key)` for sequences and `(name, channel)` for adapters so a second run is a no-op.

**Rationale:** Demos get re-seeded constantly during local development. Non-idempotent seeds force operators to drop the database, which is friction. Stable-key upsert is the canonical Phoenix-app pattern.

### D7. Library code MUST NOT change as part of this change

**Decision:** Any bug, gap, or ambiguity surfaced by demo implementation that requires editing `lib/dripdrop/**` is logged as a foundation-side issue and patched in foundation (or a follow-on library change), not worked around in the demo.

**Rationale:** This invariant keeps the change cleanly demo-scoped and prevents demo-driven scope creep into the library. Workarounds in demo code mask library bugs that other host apps will hit.

## Risks / Trade-offs

- **Demo discovers a library bug late** → Mitigation: implement the demo iteratively against the library's already-committed `bb89cc4 💧lets drip` baseline (foundation pre-archive). Any blocker becomes an explicit foundation issue with a tight loop back to library work. D7 enforces no shortcuts.
- **Demo's CI is slow because it boots Postgres + Phoenix + dispatch worker** → Mitigation: the demo's smoke test (`make ci-demo`) is a separate CI matrix entry from the library's main suite, and the library's main CI does NOT depend on demo CI. Demo CI failure does NOT block foundation library releases.
- **Phoenix LiveView 1.1 churn** → LiveView 1.x has had API changes; sticking to 1.1 stable means the demo's HEEx components are pinned. **Mitigation:** the demo is intentionally minimal — no fancy components, no streams, no async assigns beyond what the scenarios need. A future LiveView 1.2 upgrade is its own change.
- **Path-dep + `mix deps.compile` ordering** → When the library's local files change, the demo needs to be re-compiled. **Mitigation:** documented in `demo/README.md`. `mix do deps.compile dripdrop, compile` is the canonical pattern.
- **Mock_hooks divergence between library tests and demo** → Mitigation: D3 above. Both implementations are tiny; if they diverge, the divergence is documented in code comments.

## Migration Plan

This change is structurally a **lift-and-edit** of the demo content out of foundation:

1. Foundation's `proposal.md` is edited to remove the `demo-app` capability listing and the `What Changes` bullet about demo, plus the demo bullet in `Impact`.
2. Foundation's `design.md` is edited to remove `D18`. The decision is migrated verbatim into this change as `D1`.
3. Foundation's `specs/demo-app/spec.md` is deleted from foundation. Its content is re-authored here under `specs/demo-app/spec.md` (Requirement 2 about Docker is dropped — already covered by foundation tasks 1.7/1.8 which authored the files at the repo root).
4. Foundation's `tasks.md` Section 14 (15 demo tasks) is removed. Section 14a is retained but task 14a.1's description is refactored to use a `test/support` Bypass stub rather than the demo's mock_hooks endpoint. Foundation tasks 15.6 (manual deliverability smoke from the demo) is removed and migrated here. Tasks 15.7 (README quickstart) and 15.8 (Hex package exclusion) are retained in foundation; their phrasing is adjusted to not require the demo to exist.
5. `add-cold-outbound-mode/tasks.md` task 15.5 is edited to reference `add-dripdrop-demo-app` instead of foundation as the prerequisite for the optional 4th scenario.
6. After all edits, all three changes (`add-dripdrop-foundation`, `add-cold-outbound-mode`, `add-dripdrop-demo-app`) re-validate strict.

No code is moved, deleted, or written by this change's authoring step. Implementation work begins when `/opsx:apply` is run against this change after foundation archives.

**Rollback:** trivial. Delete the change directory; revert foundation's edits (proposal/design/tasks/specs); revert cold-outbound's task 15.5 phrasing. The demo capability returns to its prior in-foundation state.

## Open Questions

- **Q1.** Should the demo carry its own `dialyzer` config and PLT, or piggyback on the library's? Lean toward demo-owned since the demo's transitive dep set differs (Phoenix, LiveView, Bypass).
- **Q2.** Should `mix demo.seed` accept a `--reset` flag that drops and recreates fixtures, or should re-seeding always be additive? Lean additive (idempotent upsert), with operators expected to `mix ecto.reset` when they want a clean slate.
- **Q3.** The demo's CI matrix entry runs `docker compose up -d`. CI billing-time is a real concern. Should we add a non-Docker CI matrix entry that points the demo at a managed Postgres (GitHub Actions service container) to validate the no-Docker path? Lean yes, mirrors the library's `--no-cron` matrix entry.
