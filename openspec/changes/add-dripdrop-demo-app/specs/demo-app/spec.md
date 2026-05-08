## ADDED Requirements

### Requirement: Demo Application Lives In A Sibling Directory With A Path Dependency

The repository SHALL contain a `demo/` Phoenix application directory at the repo root (peer to `lib/`, `mix.exs`, etc.). The demo's `mix.exs` SHALL declare `{:dripdrop, path: ".."}` so the demo always builds against the working copy of the library. The demo SHALL be a complete Phoenix 1.8 + LiveView 1.1 application — runnable via `mix phx.server` after `mix setup` — and NOT a collection of standalone scripts. The library's `package:` declaration in the root `mix.exs` continues to exclude `demo/` from Hex publishing (already enforced by `add-dripdrop-foundation`).

#### Scenario: Demo boots against the local library
- **WHEN** an operator runs `cd demo && mix setup && mix phx.server` after starting the Postgres container with `docker compose up -d` from the repo root
- **THEN** the application boots, loads the local DripDrop modules (verified by `Code.ensure_loaded?(DripDrop)`), runs the host migration that wraps `DripDrop.Migration.up/0`, and serves the home page on `http://localhost:4000`.

#### Scenario: Demo is excluded from library publishing
- **WHEN** the library is packaged for Hex via `mix hex.build` (run from the repo root, NOT from `demo/`)
- **THEN** the resulting tarball does NOT contain any files from `demo/`. The exclusion is asserted by an automated check in CI.

### Requirement: Demo Ships Three Scenario LiveViews Mirroring The Library README Examples

The demo SHALL render three scenario LiveViews under `lib/dripdrop_demo_web/live/scenarios/`, each implementing one of the README examples end-to-end:

- `OnboardingLive` — SaaS onboarding sequence (welcome email → 5-min PubSub notification → 1-day conditional setup reminder → weekly Monday-9am cron digest → 7-day enterprise-only SMS).
- `LeadNurtureLive` — Lead nurture sequence with HTTP-hook lead score branching, Slack notification to sales, and webhook update to a CRM stub. Calls a deterministic in-process mock HTTP-hook endpoint shipped at `demo/lib/dripdrop_demo/mock_hooks.ex`.
- `MultiChannelTrialLive` — Trial-ending notifications fanned across email, SMS, in-app PubSub, and Telegram.

Each LiveView SHALL provide a form to enroll a fixture subscriber, display the live state of that subscriber's enrollment (current step, step executions, message events), and update via PubSub as dispatch progresses.

#### Scenario: Enroll a fixture subscriber from OnboardingLive
- **WHEN** an operator clicks "Enroll fixture user" on `/scenarios/onboarding`
- **THEN** the LiveView calls `DripDrop.enroll/1` with the fixture, the page subscribes to a PubSub topic for that enrollment, and renders the welcome-email step transitioning `scheduled → claiming → sending → sent` in real time.

#### Scenario: Lead score branching is visible in LeadNurtureLive
- **WHEN** the operator triggers `LeadNurtureLive` with a fixture lead whose mocked HTTP-hook score is 85 (≥70)
- **THEN** the LiveView shows the "Enterprise Pitch" step being scheduled and the "Notify Sales" Slack step being sent; with a score of 40, neither fires and the LiveView shows the conditions evaluating to `false`.

#### Scenario: Multi-channel fan-out is observable
- **WHEN** the operator clicks "Trigger trial-ending fan-out" on `/scenarios/multichannel-trial`
- **THEN** four step executions are scheduled (email, SMS, PubSub, Telegram), and the LiveView lists each with its target adapter and state.

### Requirement: Demo Includes A Read-Only In-App Dashboard

The demo SHALL expose a read-only dashboard under `/dashboard` that surfaces operationally interesting library state, intentionally minimal (the full editable dashboard is deferred to the future `add-dripdrop-dashboard` change). The dashboard SHALL include four LiveViews:

- `/dashboard/sequences` — list of sequences with version count, active version, and total enrollments.
- `/dashboard/enrollments` — paginated list of enrollments filterable by sequence and state.
- `/dashboard/executions` — recent `step_executions` (default last 24 h) with state, channel, adapter, and link to the linked enrollment.
- `/dashboard/events` — recent `message_events` (default last 24 h) with provider, event_type, and recipient.

Every dashboard LiveView SHALL be **read-only**: no create / update / delete actions, no forms, no mutating endpoints. `Phoenix.LiveDashboard` SHALL be mounted at `/phx-dashboard` for general OTP introspection.

#### Scenario: Dashboard never mutates state
- **WHEN** an operator navigates anywhere in `/dashboard/*`
- **THEN** every page renders without exposing forms, buttons, or actions that issue `INSERT`, `UPDATE`, or `DELETE` against the `dripdrop` schema.

#### Scenario: Pagination works on long lists
- **WHEN** more than 50 enrollments exist for a sequence
- **THEN** `/dashboard/enrollments?sequence=<id>` paginates at 50 per page using cursor-based pagination on `inserted_at`.

#### Scenario: LiveDashboard is mounted for OTP introspection
- **WHEN** an operator navigates to `/phx-dashboard`
- **THEN** the standard Phoenix LiveDashboard renders with applications, processes, ets, and metrics tabs.

### Requirement: Demo Provides An Idempotent Seed Task

The demo SHALL implement `mix demo.seed` (registered as `aliases: [seed: ["run priv/repo/seeds.exs"]]` or equivalent) that, on a freshly migrated database, creates: (a) one tenant-less email adapter using the configured local SMTP/Mailgun-test credentials, (b) one SMS adapter using a Twilio test SID, (c) the three sequences for the scenarios with their steps/transitions/conditions, (d) one fixture subscriber per scenario, and (e) one HTTP hook with a deterministic local mock-server URL.

#### Scenario: Idempotent seeding
- **WHEN** `mix demo.seed` is run twice on the same database
- **THEN** the second run is a no-op (uses `Ecto.Multi`-based upsert on `(tenant_key, key)` for sequences and `(name, channel)` for adapters) and exits 0 with no duplicate rows.

#### Scenario: Reset workflow documented
- **WHEN** an operator wants a clean fixture set
- **THEN** `demo/README.md` documents `mix ecto.reset && mix demo.seed` as the canonical reset path; `mix demo.seed` itself does NOT drop or destructively mutate existing data.

### Requirement: Demo Wires The Webhook Ingest Plug And Unsubscribe Handler

The demo's `Endpoint` SHALL mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token`. The demo SHALL configure `unsubscribe_url_builder` and `unsubscribe_secret` so RFC 8058 headers resolve to a working URL during local testing. The demo's mock HTTP-hook server SHALL listen on a deterministic local port set in `demo/config/dev.exs` so seeded HTTP hooks can target it.

#### Scenario: Local one-click unsubscribe round-trip
- **WHEN** the demo sends an email step with unsubscribe headers enabled through a local Mailgun sandbox and the operator clicks the List-Unsubscribe-Post link
- **THEN** the demo's unsubscribe handler verifies the signed token, writes a `suppressions` row, and returns `200`.

#### Scenario: Mock HTTP hook is reachable from seeded sequences
- **WHEN** an enrollment in `LeadNurtureLive` reaches the lead-score HTTP hook step
- **THEN** dispatch issues an HTTP request to the demo's mock-hooks endpoint, receives a deterministic response (lead score chosen by the LiveView form), and proceeds with branching evaluation.

### Requirement: Demo Mix File Defines A `mix quality` Alias

The demo's `mix.exs` SHALL define an alias `quality` running `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`. Quality tooling deps (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`) SHALL be `only: [:dev, :test], runtime: false` in the demo's `mix.exs`. The library's own `mix.exs` already defines its `quality` alias (foundation task 1.3).

#### Scenario: `mix quality` passes on a clean demo checkout
- **WHEN** an operator runs `mix quality` from `demo/` on a clean checkout after `mix setup`
- **THEN** all sub-commands exit 0.

#### Scenario: Demo CI is independent of library CI
- **WHEN** the library's main CI matrix runs (`mix quality`, `mix test`, `mix dialyzer` from the repo root)
- **THEN** demo-side quality issues do NOT cause the library's main CI to fail. Demo CI runs as a separate matrix entry that only fires when `demo/**` files change or on a release-tagged commit.

### Requirement: Demo Documents The Run Loop In Its Own README

The demo SHALL ship `demo/README.md` documenting: prerequisites (`asdf`, Docker), `docker compose up -d` from the repo root, `mix setup`, `mix demo.seed`, `mix phx.server`, the URLs of each scenario and dashboard, and how to point the demo at a remote Postgres if Docker is unavailable. The documentation SHALL include the canonical `mix do deps.compile dripdrop, compile` pattern for working against an evolving local library copy. The library's top-level `README.md` SHALL link to `demo/README.md`.

#### Scenario: First-time operator can boot the demo
- **WHEN** an operator follows `demo/README.md` from a clean clone
- **THEN** they reach a working `http://localhost:4000` with seeded scenarios in under ten minutes, with no manual SQL or undocumented environment variables.

#### Scenario: No-Docker fallback is documented
- **WHEN** an operator's environment prohibits Docker (corporate restriction, CI without Docker support)
- **THEN** `demo/README.md` documents the alternative path: target an existing Postgres instance via `DATABASE_URL`, run `mix dripdrop.setup --no-cron`, accept that cron-driven steps are disabled, and start the demo as usual; the demo emits a startup warning but boots successfully.

### Requirement: Demo Smoke Test Runs As A CI Matrix Entry

The repository SHALL include a CI step (`make ci-demo` or equivalent invoked from `.github/workflows/ci.yml`) that: (a) runs `docker compose up -d` from the repo root, (b) `cd demo`, (c) `mix setup`, (d) `mix demo.seed`, (e) `mix test`, (f) `mix quality`. The step SHALL run on every PR that touches `demo/**` and on every release-tagged commit. Library-only changes (no `demo/**` files touched) SHALL NOT trigger the demo CI step.

#### Scenario: Demo CI runs on a demo-touching PR
- **WHEN** a PR modifies `demo/lib/dripdrop_demo_web/live/scenarios/onboarding_live.ex`
- **THEN** the CI workflow runs the demo smoke step in addition to the library's main matrix; both must pass for the PR to be mergeable.

#### Scenario: Library-only PR skips demo CI
- **WHEN** a PR modifies only `lib/dripdrop/**` and `test/dripdrop/**` with no `demo/**` files touched
- **THEN** the demo CI step is skipped; only the library's main CI matrix runs.
