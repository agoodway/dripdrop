# demo-app

## Purpose

The `demo-app` capability is a Phoenix 1.8 + LiveView 1.1 application living at `demo/` (sibling to `lib/`) that consumes `:dripdrop` as a path dep and exercises the library end-to-end. It serves as the canonical reference operators read to learn how to integrate DripDrop, and it validates that the foundation and cold-outbound public-API surfaces compose the way the library README claims. The demo is not a host-app dependency — it is an operator-facing reference.

## Requirements

### Requirement: Demo Application Lives In A Sibling Directory With A Path Dependency

The repository SHALL contain a `demo/` Phoenix application directory at the repo root (peer to `lib/`, `mix.exs`, etc.). The demo's `mix.exs` SHALL declare `{:dripdrop, path: ".."}` so the demo always builds against the working copy of the library. The demo SHALL be a complete Phoenix 1.8 + LiveView 1.1 application — runnable via `mix phx.server` after `mix setup` — and NOT a collection of standalone scripts. The library's `package:` declaration in the root `mix.exs` continues to exclude `demo/` from Hex publishing (already enforced by `add-dripdrop-foundation`).

#### Scenario: Demo boots against the local library
- **WHEN** an operator runs `cd demo && mix setup && mix phx.server` after starting the Postgres container with `docker compose up -d` from the repo root
- **THEN** the application boots, loads the local DripDrop modules (verified by `Code.ensure_loaded?(DripDrop)`), runs the host migration that wraps `DripDrop.Migration.up/0`, and serves the home page on `http://localhost:4012`.

#### Scenario: Demo is excluded from library publishing
- **WHEN** the library is packaged for Hex via `mix hex.build` (run from the repo root, NOT from `demo/`)
- **THEN** the resulting tarball does NOT contain any files from `demo/`. The exclusion is asserted by an automated check in CI.

### Requirement: Demo Ships Three Scenario LiveViews

The demo SHALL render three scenario LiveViews under `lib/dripdrop_demo_web/live/scenarios/`:

- `OnboardingLive` — welcome email, in-app PubSub nudge, HTTP setup-status check, SMS follow-up, and Telegram team update.
- `LeadNurtureLive` — email verification hook, HTTP lead-score branching, nurture email, PubSub sales alert, and CRM webhook update.
- `OutboundLive` — cold outbound email thread for Elixir, Phoenix, and LiveView consulting services with multiple recipients and sender-pool behavior.

Each LiveView SHALL provide a form to enroll one or more fixture subscribers, display the live state of those enrollments (current step, step executions, message events), and update via PubSub as dispatch progresses.

#### Scenario: Enroll a fixture subscriber from OnboardingLive
- **WHEN** an operator clicks "Start Onboarding Sequence" on `/scenarios/onboarding`
- **THEN** the LiveView calls `DripDrop.enroll/1` with the fixture, the page subscribes to a PubSub topic for that enrollment, and renders the welcome-email step transitioning `scheduled → claiming → sending → sent` in real time.

#### Scenario: Lead score branching is visible in LeadNurtureLive
- **WHEN** the operator starts the high-fit lead path
- **THEN** the LiveView shows the GoodVerify email check, lead-score HTTP hook, predicate branch, sales PubSub alert, and hot-lead CRM webhook update.

#### Scenario: Nurture and invalid-email branches are visible
- **WHEN** the operator starts the nurture or invalid-email lead path
- **THEN** the LiveView shows the branch decisions and only the messages allowed by the hook and predicate results.

### Requirement: OutboundLive Demonstrates Sender Pools And Threaded Email

`OutboundLive` at `/scenarios/outbound` SHALL exercise the cold-outbound public-API surface against the seeded `outbound_pool` and a 3-step outbound sequence configured with `mode: :outbound` and `config["pool_id"]`. The LiveView SHALL use the same scenario layout as onboarding and lead nurture: sequence steps/code, sequence messages, and runtime logs. The sequence messages panel SHALL render the threaded outbound emails with `Message-ID`, `In-Reply-To`, and `References` headers visible. Enrolled prospects SHALL be presented in an at-a-glance grid (one card per prospect) so pool dispatch parallelism is visible — clicking a card drives the message detail pane below.

#### Scenario: WDRR distributes outbound enrollments across the pool
- **WHEN** an operator clicks "Outbound Campaign" on `/scenarios/outbound`
- **THEN** eight enrollments are created with `effective_mode: :outbound` and `adapter_id` pinned by WDRR; each prospect card displays its pinned adapter via `pin_breadcrumb`, and at least one enrollment is pinned to each of the three pool members (≥1 per adapter over 8 enrollments at weight 1).

#### Scenario: Threading chain is visible in the message panel
- **WHEN** an enrollment has progressed through at least two steps
- **THEN** the message detail pane lists the email thread in order and exposes the current `Message-ID`, `In-Reply-To`, and `References` values for the selected recipient.

### Requirement: OutboundLive Demonstrates Sender Pool Dynamics And Operator Outcomes

`OutboundLive` SHALL render a sender pool panel above the prospect grid showing per-sender health pill, capacity bar (`sent_today / effective_cap_today`), min-gap meter, and an operator control strip (Activate / Probe / Rest). The demo SHALL provide eight scripted outcomes — one per prospect — that exercise the library's reply ingestion, suppression, ramp cap, and pool failover paths via a `DripdropDemo.Scenarios.Outbound.Simulators` module that wraps `DripDrop.ingest_inbound_message/2`, `DripDrop.suppress/1`, `DripDrop.set_adapter_health/2`, and direct `MessageEvent` inserts (for hard/soft bounce; the only place outside the library that touches `MessageEvent` rows directly).

#### Scenario: Sender pool panel reflects health changes via PubSub
- **WHEN** `DripDrop.set_adapter_health/2` flips a pool member to `:resting`
- **THEN** the pool panel re-renders within ~200ms (driven by `[:dripdrop, :health, :state_changed]` telemetry → `adapter:<id>` PubSub topic) and shows the resting state.

#### Scenario: Scripted outcomes resolve via auto-play timer
- **WHEN** the operator clicks "Outbound Campaign" and the first send for each prospect lands as `[:dripdrop, :dispatch, :sent]`
- **THEN** an `:autoplay_outcome` message is scheduled per enrollment via `Process.send_after/3`, which then invokes `Simulators.trigger/2` with that prospect's mapped outcome (e.g., Eli → `:hard_bounce` produces a `MessageEvent` with `event_type: "bounced"` plus a `Suppression` row; Quinn → `:rest_pinned_sender` rests the pinned adapter triggering a pool rebind).

#### Scenario: Reset capacity restores fresh state
- **WHEN** an operator clicks "Reset capacity" on the sender pool panel
- **THEN** today's `sent` `MessageEvent` rows for pool adapters are backdated out of the day and adapter caps are restored from `Outbound.daily_cap_default/0` and `Outbound.min_gap_default/0`; the panel renders `0/<daily_cap>` capacity bars.

### Requirement: Demo Uses Short Observable Timing

The demo SHALL persist short DripDrop delay values so each scenario can be observed end-to-end in seconds. The library scheduler SHALL be unchanged.

#### Scenario: Library scheduler behavior is unchanged
- **WHEN** the demo persists a short delay for a scenario step
- **THEN** the library's PgFlow scheduler schedules and dispatches that step exactly as it would for any other delay; no library-side time-scaling exists, and `mix dripdrop.check_schema` continues to verify the unmodified library schema.

### Requirement: Outbound Messages Are Previewable In The Scenario UI

`OutboundLive` SHALL render the outbound email thread directly in the scenario UI. The demo SHALL NOT rely on `/dev/mailbox` for production-facing demos.

#### Scenario: Outbound email thread is visible in the scenario
- **WHEN** a cold outbound enrollment sends one or more email steps
- **THEN** `OutboundLive` shows the sent email content in the sequence messages panel without requiring a separate mailbox preview.

### Requirement: Demo Includes Phoenix LiveDashboard In Dev

`Phoenix.LiveDashboard` SHALL be mounted at `/phx-dashboard` in dev for OTP introspection.

#### Scenario: LiveDashboard is mounted for OTP introspection
- **WHEN** an operator navigates to `/phx-dashboard`
- **THEN** the standard Phoenix LiveDashboard renders with applications, processes, ets, and metrics tabs.

### Requirement: Demo Provides An Idempotent Seed Task

The demo SHALL implement `mix demo.seed` (registered as `aliases: [seed: ["run priv/repo/seeds.exs"]]` or equivalent) that, on a freshly migrated database, creates: (a) local/sandboxed channel adapters, (b) the three sequences for the scenarios with their steps/transitions/conditions, (c) fixture subscribers, and (d) deterministic local mock-hook URLs.

#### Scenario: Idempotent seeding
- **WHEN** `mix demo.seed` is run twice on the same database
- **THEN** the second run is a no-op (uses `Ecto.Multi`-based upsert on `(tenant_key, key)` for sequences and `(name, channel)` for adapters) and exits 0 with no duplicate rows.

#### Scenario: Reset workflow documented
- **WHEN** an operator wants a clean fixture set
- **THEN** `demo/README.md` documents `mix ecto.reset && mix demo.seed` as the canonical reset path; `mix demo.seed` itself does NOT drop or destructively mutate existing data.

### Requirement: Demo Wires The Webhook Ingest Plug And Unsubscribe Handler

The demo's `Endpoint` SHALL mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token`. The demo SHALL configure `unsubscribe_url_builder` and `unsubscribe_secret` so RFC 8058 headers resolve to a working URL during local testing. The demo's mock HTTP-hook server SHALL listen on a deterministic local port set in `demo/config/dev.exs` so seeded HTTP hooks can target it.

#### Scenario: One-click unsubscribe route is wired
- **WHEN** the demo renders an email step with unsubscribe headers enabled
- **THEN** the generated List-Unsubscribe URL targets the demo's unsubscribe handler, which verifies the signed token, writes a `suppressions` row, and returns `200`.

#### Scenario: Mock HTTP hook is reachable from seeded sequences
- **WHEN** an enrollment in `LeadNurtureLive` reaches the lead-score HTTP hook step
- **THEN** dispatch issues an HTTP request to the demo's mock-hooks endpoint, receives a deterministic response (lead score chosen by the LiveView form), and proceeds with branching evaluation.

### Requirement: Demo Mix File Defines A `mix quality` Alias

The demo's `mix.exs` SHALL define an alias `quality` running `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`. Quality tooling deps (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`) SHALL be `only: [:dev, :test], runtime: false` in the demo's `mix.exs`. The library's own `mix.exs` already defines its `quality` alias (foundation task 1.3).

#### Scenario: `mix quality` passes on a clean demo checkout
- **WHEN** an operator runs `mix quality` from `demo/` on a clean checkout after `mix setup`
- **THEN** all sub-commands exit 0.


### Requirement: Demo Documents The Run Loop In Its Own README

The demo SHALL ship `demo/README.md` documenting the run loop, local ports, scenario URLs, `/phx-dashboard`, production-safe mocked delivery, short demo timing, and useful commands. The library's top-level `README.md` SHALL link to `demo/README.md`.

#### Scenario: First-time operator can boot the demo
- **WHEN** an operator follows `demo/README.md` from a clean clone
- **THEN** they reach a working `http://localhost:4012` with seeded scenarios in under ten minutes, with no manual SQL or undocumented environment variables.

#### Scenario: Demo README states the delivery boundary
- **WHEN** an operator reads `demo/README.md`
- **THEN** the README explains that PubSub dispatches locally while email, SMS, Telegram, and webhooks are rendered or mocked for a production-safe demo.

