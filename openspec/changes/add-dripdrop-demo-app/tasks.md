## 0. Prerequisites

- [ ] 0.1 Confirm `add-dripdrop-foundation` is archived (or its remaining release tasks are green) before starting demo implementation. The demo depends on the public `DripDrop.*` API surface defined by foundation.
- [ ] 0.2 Read `proposal.md`, `design.md`, and `specs/demo-app/spec.md` to internalize design decisions D1–D7. Decision D7 (no library code changes from this change) is a hard invariant.

## 1. Phoenix app scaffolding

- [ ] 1.1 Generate `demo/` Phoenix 1.8 + LiveView 1.1 app via `mix phx.new demo --module DripdropDemo --app dripdrop_demo --live` (run from a scratch dir, then move into the repo as a sibling to `lib/`). Verify the directory layout: `demo/lib/`, `demo/test/`, `demo/priv/`, `demo/mix.exs`, `demo/config/`.
- [ ] 1.2 Edit `demo/mix.exs` to declare `{:dripdrop, path: ".."}`, mirror the library's `mix quality` alias and quality deps (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna` — all `only: [:dev, :test], runtime: false`), set `preferred_envs: [precommit: :test, quality: :test]`, and add `seed: ["run priv/repo/seeds.exs"]` to aliases. Add `bypass ~> 2.1` (test/dev only) for the mock-hooks server.
- [ ] 1.3 Configure `demo/config/dev.exs` to point at the Docker Postgres instance (`localhost:54325`, `dripdrop_dev`). Add `config :dripdrop, repo: DripdropDemo.Repo, scheduler: DripDrop.Schedulers.Pgflow`. Configure mock-hooks port (e.g., `4001`) so seeded HTTP hooks can reach it.
- [ ] 1.4 Wire `demo/lib/dripdrop_demo/application.ex` to start (in order): `DripdropDemo.Repo`, the host PgFlow with `jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]`, the Phoenix `Endpoint`, the `MockHooks` Bypass server (test/dev only). Call `DripDrop.startup_check/0` and log warnings via the demo's Logger.
- [ ] 1.5 Mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` in `DripdropDemoWeb.Router`. Mount `DripDrop.Web.UnsubscribePlug` at `/u/:token` via the same router. Mount `Phoenix.LiveDashboard` at `/phx-dashboard` (gated to dev/test environments).
- [ ] 1.6 Configure `unsubscribe_url_builder` (function returning `"http://localhost:4000/u/#{token}"`) and `unsubscribe_secret` in `demo/config/dev.exs` so RFC 8058 round-trip works against a local SMTP/Mailgun-test inbox.
- [ ] 1.7 Wire `demo/config/test.exs` for ExUnit + Bypass. Confirm `:dripdrop, scheduler: DripDrop.Schedulers.Test` for fast deterministic tests. Configure mock-hooks port to a different value than dev (e.g., `4901`) so dev and test can run in parallel.

## 2. Mock HTTP-hook server

- [ ] 2.1 Implement `demo/lib/dripdrop_demo/mock_hooks.ex` as a Plug-based HTTP server (Bypass-shaped) that exposes deterministic endpoints: `/lead-score?lead_id=<id>` returns a configurable JSON response, `/crm-update` accepts a POST and returns 204. Default lead-score values come from a seeded fixture; tests can override.
- [ ] 2.2 Wire `MockHooks` into `DripdropDemo.Application` as a child spec under `dev` and `test` only — never `prod`. Document why in module docs.
- [ ] 2.3 Smoke test: hit each mock endpoint via `Req` from inside `iex -S mix` against the running demo and confirm deterministic responses.

## 3. Scenario LiveViews

- [ ] 3.1 Implement `DripdropDemoWeb.Scenarios.OnboardingLive` matching README example 1: welcome email (immediate) → 5-min PubSub notification → 1-day conditional setup reminder → weekly Monday-9am cron digest → 7-day enterprise-only SMS. The LiveView SHALL provide a "Enroll fixture user" button, subscribe to PubSub for the resulting enrollment, and render `step_executions` state transitions in real time. Use `Phoenix.PubSub.subscribe/2` against a topic named `"enrollment:#{enrollment_id}"` published by a dispatch telemetry handler.
- [ ] 3.2 Implement `DripdropDemoWeb.Scenarios.LeadNurtureLive` matching README example 2: HTTP-hook lead score branching (`>=70` → "Enterprise Pitch", `<70` → "Standard Pitch"), Slack notification on enterprise leads, webhook update to a CRM stub. The LiveView SHALL include a form to choose the simulated lead score (which the mock-hooks server returns), trigger an enrollment, and show condition evaluation results live.
- [ ] 3.3 Implement `DripdropDemoWeb.Scenarios.MultiChannelTrialLive` matching README example 3: trial-ending notifications fanned across email, SMS, in-app PubSub, and Telegram (in parallel from a single trigger). The LiveView SHALL display all four step executions with their target adapters and states updating in real time.
- [ ] 3.4 Each scenario LiveView lives in its own directory `demo/lib/dripdrop_demo_web/live/scenarios/<name>/` with its own `index.html.heex` and any helper modules. NO shared business logic between scenarios — each is self-contained for clarity (D1 trade-off mitigation).
- [ ] 3.5 Implement `DripdropDemoWeb.Live.PubSubBridge` (or similar) — a small GenServer that listens to `[:dripdrop, :dispatch, ...]` telemetry and republishes to scenario-specific Phoenix.PubSub topics so the LiveViews can subscribe. Document the bridge in `demo/README.md`.

## 4. Read-only dashboard

- [ ] 4.1 Implement `DripdropDemoWeb.Dashboard.SequencesLive` at `/dashboard/sequences` — list of sequences with version count, active version, total enrollments. Read-only.
- [ ] 4.2 Implement `DripdropDemoWeb.Dashboard.EnrollmentsLive` at `/dashboard/enrollments` — paginated list (50/page) of enrollments filterable by sequence and state via querystring. Cursor pagination on `inserted_at`. Read-only.
- [ ] 4.3 Implement `DripdropDemoWeb.Dashboard.ExecutionsLive` at `/dashboard/executions` — recent `step_executions` (default last 24h) with state, channel, adapter, and link to enrollment. Read-only.
- [ ] 4.4 Implement `DripdropDemoWeb.Dashboard.EventsLive` at `/dashboard/events` — recent `message_events` (default last 24h) with provider, event_type, recipient. Read-only.
- [ ] 4.5 Confirm via test that no dashboard page exposes any form, button, or endpoint that issues `INSERT`, `UPDATE`, or `DELETE` against the `dripdrop` schema. Pattern: a `Plug.Conn`-level test asserts only `:get` routes are registered under `/dashboard/*`.

## 5. Seed task

- [ ] 5.1 Implement `demo/priv/repo/seeds.exs` (run via `mix demo.seed`): idempotent (`Ecto.Multi`-based upsert on `(tenant_key, key)` for sequences, `(name, channel)` for adapters); creates one email adapter (Mailgun-sandbox or local Mailpit), one SMS adapter (Twilio test SID), all three sequences with their steps/transitions/conditions, fixture subscribers, and one HTTP hook pointing at the local mock server.
- [ ] 5.2 Wire `mix demo.seed` alias in `demo/mix.exs`. Verify `mix demo.seed && mix demo.seed` exits 0 with no duplicate rows.
- [ ] 5.3 Document `mix ecto.reset && mix demo.seed` as the canonical reset workflow in `demo/README.md`.

## 6. Documentation

- [ ] 6.1 Author `demo/README.md` documenting: prerequisites (`asdf`, Docker), `docker compose up -d` from the repo root, `mix setup`, `mix demo.seed`, `mix phx.server`, scenario URLs (`/scenarios/onboarding`, `/scenarios/lead-nurture`, `/scenarios/multichannel-trial`), dashboard URLs (`/dashboard/{sequences,enrollments,executions,events}`, `/phx-dashboard`), the offline / no-Docker fallback path (target an existing Postgres via `DATABASE_URL`, run `mix dripdrop.setup --no-cron`).
- [ ] 6.2 Document the path-dep development loop: `mix do deps.compile dripdrop, compile` after pulling library changes; the demo always rebuilds against the working copy.
- [ ] 6.3 Add a "Common pitfalls" section to `demo/README.md`: stale compiled artifacts, Postgres port collisions with other DripDrop forks, `pg_cron` extension missing on managed Postgres.
- [ ] 6.4 Link `demo/README.md` from the top-level `README.md` (small edit; one line under the existing "Quick Start" section).

## 7. CI integration

- [ ] 7.1 Add `make ci-demo` (or equivalent shell script) that runs `docker compose up -d`, waits for Postgres readiness, `cd demo`, `mix setup`, `mix demo.seed`, `mix test`, `mix quality`. Idempotent and safe to run repeatedly.
- [ ] 7.2 Add a new GitHub Actions matrix entry that runs `make ci-demo` on PRs touching `demo/**` or on release-tagged commits. Library-only PRs SHALL NOT trigger this entry.
- [ ] 7.3 Add a no-Docker matrix entry pointing the demo at a GitHub Actions service-container Postgres (alternative path documented in `demo/README.md`).

## 8. Tests

- [ ] 8.1 Demo-side ExUnit tests under `demo/test/`: each scenario LiveView has a smoke test that enrolls a fixture and asserts the first step transitions through the documented states.
- [ ] 8.2 Mock-hooks tests: assert deterministic responses for `/lead-score` and `/crm-update`.
- [ ] 8.3 Dashboard read-only assertion test (referenced in 4.5).
- [ ] 8.4 Seed idempotency test: run seeds twice in a fresh test database, assert no duplicates.

## 9. Manual deliverability smoke (release validation)

- [ ] 9.1 Manual deliverability smoke from the demo: enroll a fixture subscriber whose email is a mailbox you control (real Gmail or Outlook account, NOT a sandbox-only address), dispatch a real Mailgun-sandbox sequence of 25 messages from a properly warmed sender; verify SPF/DKIM/DMARC pass in Gmail's "Show original" view, verify `List-Unsubscribe` and `List-Unsubscribe-Post` headers are present when the step opts in, verify one-click POST to `/u/:token` writes a `suppressions` row in the demo's database. Document outcome in the change's PR description (or release notes) before tagging.

## 10. Validation and release

- [ ] 10.1 Run `openspec validate add-dripdrop-demo-app --strict` — must pass.
- [ ] 10.2 Run `mix quality` from `demo/` — must pass.
- [ ] 10.3 Run `mix test` from `demo/` — must pass.
- [ ] 10.4 Run `mix dialyzer` from `demo/` (with demo-owned PLT per design Q1) — no warnings.
- [ ] 10.5 Run `make ci-demo` end-to-end locally to confirm the CI step works.
- [ ] 10.6 Run the manual deliverability smoke (task 9.1).
- [ ] 10.7 Update top-level `README.md` to link to `demo/README.md` (task 6.4 covered this; final verification step here).
- [ ] 10.8 Tag this change as ready-to-archive after merge: `openspec archive add-dripdrop-demo-app`.
