## ADDED Requirements

### Requirement: Demo Application Lives In A Sibling Directory With A Path Dependency

The repository SHALL contain a `demo/` Phoenix application directory at the repo root (peer to `lib/`, `mix.exs`, etc.). The demo's `mix.exs` SHALL declare `{:dripdrop, path: ".."}` so the demo always builds against the working copy of the library. The demo SHALL be a complete Phoenix 1.8 + LiveView 1.1 application — runnable via `mix phx.server` after `mix setup` — and NOT a collection of standalone scripts.

#### Scenario: Demo boots against the local library
- **WHEN** an operator runs `cd demo && mix setup && mix phx.server` after starting the Docker Postgres image
- **THEN** the application boots, loads the local DripDrop modules (verified by `Code.ensure_loaded?(DripDrop)`), runs migrations, and serves the home page on `http://localhost:4000`.

#### Scenario: Demo is excluded from library publishing
- **WHEN** the library is packaged for Hex via `mix hex.build`
- **THEN** the `demo/` directory is excluded from the package (declared via `package: [files: [...]]` in the library `mix.exs`).

### Requirement: Top-Level Docker Image Bundles Postgres 18 With pgmq And pg_cron

The repository root SHALL contain a `Dockerfile` and a `docker-compose.yml` that build a Postgres 18 image with `pg_cron` preloaded via `shared_preload_libraries`. `pgmq` and `pgflow` SHALL be installed by PgFlow-generated migrations, mirroring the host-app setup path documented by PgFlow. The compose file SHALL expose a single service named `db`, set `cron.database_name` to the demo database name, and publish a stable host port for local development.

#### Scenario: docker compose up brings up Postgres with extensions
- **WHEN** an operator runs `docker compose up -d` from the repository root
- **THEN** the `db` container starts, listens on the published port, and `SELECT extname FROM pg_extension` includes `pgmq`, `pg_cron`, `citext`, `pg_trgm`, and `pgcrypto`.

#### Scenario: --no-cron alternative is documented
- **WHEN** an operator's host does not support `pg_cron` (e.g., a managed Postgres without that extension)
- **THEN** the demo's `README.md` documents the alternative path: skip Docker, target an existing Postgres instance, and run `mix dripdrop.setup --no-cron`; the demo SHALL still boot but cron-driven steps SHALL be disabled and emit a startup warning.

### Requirement: Demo Ships Three Scenario LiveViews Mirroring The Library README Examples

The demo SHALL render three scenario LiveViews under `lib/dripdrop_demo_web/live/scenarios/`, each implementing one of the README examples end-to-end:

- `OnboardingLive` — SaaS onboarding sequence (welcome email → 5-min PubSub notification → 1-day conditional setup reminder → weekly Monday-9am cron digest → 7-day enterprise-only SMS).
- `LeadNurtureLive` — Lead nurture sequence with HTTP-hook lead score branching, Slack notification to sales, and webhook update to a CRM stub.
- `MultiChannelTrialLive` — Trial-ending notifications fanned across email, SMS, in-app PubSub, and Telegram.

Each LiveView SHALL provide a form to enroll a fixture subscriber, display the live state of that subscriber's enrollment (current step, step executions, message events), and update via PubSub as dispatch progresses.

#### Scenario: Enroll a fixture subscriber from OnboardingLive
- **WHEN** an operator clicks "Enroll fixture user" on `/scenarios/onboarding`
- **THEN** the LiveView calls `DripDrop.enroll/1` with the fixture, the page subscribes to a PubSub topic for that enrollment, and renders the welcome-email step transitioning `scheduled → claiming → sending → sent` in real time.

#### Scenario: Lead score branching is visible
- **WHEN** the operator triggers `LeadNurtureLive` with a fixture lead whose mocked HTTP-hook score is 85 (≥70)
- **THEN** the LiveView shows the "Enterprise Pitch" step being scheduled and the "Notify Sales" Slack step being sent; with a score of 40, neither fires and the LiveView shows the conditions evaluating to `false`.

#### Scenario: Multi-channel fan-out is observable
- **WHEN** the operator clicks "Trigger trial-ending fan-out" on `/scenarios/multichannel-trial`
- **THEN** four step executions are scheduled (email, SMS, PubSub, Telegram), and the LiveView lists each with its target adapter and state.

### Requirement: Demo Includes A Read-Only In-App Dashboard

The demo SHALL expose a read-only dashboard under `/dashboard` that surfaces the operationally interesting library state, intentionally minimal (the full editable dashboard is deferred to the `add-dripdrop-dashboard` change). The dashboard SHALL include four LiveViews:

- `/dashboard/sequences` — list of sequences with version count, active version, and total enrollments.
- `/dashboard/enrollments` — paginated list of enrollments filterable by sequence and state.
- `/dashboard/executions` — recent `step_executions` (default last 24 h) with state, channel, adapter, and link to the linked enrollment.
- `/dashboard/events` — recent `message_events` (default last 24 h) with provider, event_type, and recipient.

Every dashboard LiveView SHALL be **read-only**: no create / update / delete actions. Phoenix.LiveDashboard SHALL be mounted at `/phx-dashboard` for general OTP introspection.

#### Scenario: Dashboard never mutates state
- **WHEN** an operator navigates anywhere in `/dashboard/*`
- **THEN** every page renders without exposing forms, buttons, or actions that issue `INSERT`, `UPDATE`, or `DELETE` against the `dripdrop` schema.

#### Scenario: Pagination works on long lists
- **WHEN** more than 50 enrollments exist for a sequence
- **THEN** `/dashboard/enrollments?sequence=<id>` paginates at 50 per page using cursor-based pagination on `inserted_at`.

### Requirement: Demo Provides A Seed Task

The demo SHALL implement `mix demo.seed` (registered as `aliases: [seed: ["run priv/repo/seeds.exs"]]` or equivalent) that, on a freshly migrated database, creates: (a) one tenant-less email adapter using the configured local SMTP/Mailgun-test credentials, (b) one SMS adapter using a Twilio test SID, (c) the three sequences for the scenarios, (d) one fixture subscriber per scenario, and (e) one HTTP hook with a deterministic mock-server URL.

#### Scenario: Idempotent seeding
- **WHEN** `mix demo.seed` is run twice on the same database
- **THEN** the second run is a no-op (uses `Ecto.Multi.upsert/4` or equivalent on `(tenant_key, key)` and `(name, channel)`) and exits 0.

### Requirement: Demo Wires The Webhook Ingest Plug And Unsubscribe Handler

The demo's `Endpoint` SHALL mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token`. The demo SHALL configure `unsubscribe_url_builder` and `unsubscribe_secret` so RFC 8058 headers resolve to a working URL during local testing.

#### Scenario: Local one-click unsubscribe round-trip
- **WHEN** the demo sends an email step with unsubscribe headers enabled through a local Mailgun sandbox and the operator clicks the List-Unsubscribe-Post link
- **THEN** the demo's unsubscribe handler verifies the signed token, writes a `suppressions` row, and returns `200`.

### Requirement: Demo Mix File Defines A `mix quality` Alias

The demo's `mix.exs` SHALL define an alias `quality` running `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow --config`, `ex_dna`, `doctor`, `credo --strict`. The library's own `mix.exs` SHALL define the same alias (sans Phoenix-specific concerns). Quality tooling deps (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`) SHALL be `only: [:dev, :test], runtime: false`.

#### Scenario: mix quality passes on a clean repo
- **WHEN** an operator runs `mix quality` from the repo root on a clean checkout
- **THEN** all sub-commands exit 0 and CI uses this single alias as its quality gate.

### Requirement: Demo Documents The Run Loop In Its Own README

The demo SHALL ship `demo/README.md` documenting: prerequisites (`asdf`, Docker), `docker compose up -d` from the repo root, `mix setup`, `mix demo.seed`, `mix phx.server`, the URLs of each scenario and dashboard, and how to point the demo at a remote Postgres if Docker is unavailable. The library's top-level `README.md` SHALL link to `demo/README.md`.

#### Scenario: First-time operator can boot the demo
- **WHEN** an operator follows the demo README from a clean clone
- **THEN** they reach a working `http://localhost:4000` with seeded scenarios in under ten minutes, with no manual SQL or undocumented environment variables.
