## 0. Prerequisites

- [x] 0.1 Confirm `add-dripdrop-foundation` is archived (or its remaining release tasks are green) before starting demo implementation. The demo depends on the public `DripDrop.*` API surface defined by foundation.
- [x] 0.2 Read `proposal.md`, `design.md`, and `specs/demo-app/spec.md` to internalize design decisions D1–D7. Decision D7 (no library code changes from this change) is a hard invariant.

## 1. Phoenix app scaffolding

- [x] 1.1 Generate `demo/` Phoenix 1.8 + LiveView 1.1 app via `mix phx.new demo --module DripdropDemo --app dripdrop_demo --live` (run from a scratch dir, then move into the repo as a sibling to `lib/`). Verify the directory layout: `demo/lib/`, `demo/test/`, `demo/priv/`, `demo/mix.exs`, `demo/config/`.
- [x] 1.2 Edit `demo/mix.exs` to declare `{:dripdrop, path: ".."}`, mirror the library's `mix quality` alias and quality deps (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna` — all `only: [:dev, :test], runtime: false`), set `preferred_envs: [precommit: :test, quality: :test]`, and add `seed: ["run priv/repo/seeds.exs"]` to aliases. Add `bypass ~> 2.1` (test/dev only) for the mock-hooks server.
- [x] 1.3 Configure `demo/config/dev.exs` to point at the Docker Postgres instance (`localhost:54325`, `dripdrop_dev`). Add `config :dripdrop, repo: DripdropDemo.Repo, scheduler: DripDrop.Schedulers.Pgflow`. Configure mock-hooks port `4013` so seeded HTTP hooks can reach it.
- [x] 1.4 Wire `demo/lib/dripdrop_demo/application.ex` to start (in order): `DripdropDemo.Repo`, the host PgFlow with `jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]`, the Phoenix `Endpoint`, the `MockHooks` Bypass server (test/dev only). Call `DripDrop.startup_check/0` and log warnings via the demo's Logger.
- [x] 1.5 Mount `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` in `DripdropDemoWeb.Router`. Mount `DripDrop.Web.UnsubscribePlug` at `/u/:token` via the same router. Mount `Phoenix.LiveDashboard` at `/phx-dashboard` (gated to dev/test environments).
- [x] 1.6 Configure `unsubscribe_url_builder` and `unsubscribe_secret` in `demo/config/dev.exs` so RFC 8058 headers can be rendered by local/sandboxed email providers.
- [x] 1.7 Wire `demo/config/test.exs` for ExUnit + Bypass. Confirm `:dripdrop, scheduler: DripDrop.Schedulers.Test` for fast deterministic tests. Configure mock-hooks port to a different value than dev (e.g., `4901`) so dev and test can run in parallel.

## 2. Mock HTTP-hook server

- [x] 2.1 Implement `demo/lib/dripdrop_demo/mock_hooks.ex` as a Plug-based HTTP server (Bypass-shaped) that exposes deterministic endpoints: `/lead-score?lead_id=<id>` returns a configurable JSON response, `/crm-update` accepts a POST and returns 204. Default lead-score values come from a seeded fixture; tests can override.
- [x] 2.2 Wire `MockHooks` into `DripdropDemo.Application` as a child spec under `dev` and `test` only — never `prod`. Document why in module docs.
- [x] 2.3 Smoke test: hit each mock endpoint via `Req` from inside `iex -S mix` against the running demo and confirm deterministic responses.

## 3. Scenario LiveViews

- [x] 3.1 Implement `DripdropDemoWeb.Scenarios.OnboardingLive`: welcome email, in-app PubSub nudge, HTTP setup-status check, setup SMS, Telegram team update, sequence code mirror, message stream, and runtime logs.
- [x] 3.2 Implement `DripdropDemoWeb.Scenarios.LeadNurtureLive`: GoodVerify-style Elixir email-verification hook, HTTP lead-score hook, branch decisions, nurture email, PubSub sales alert, and CRM webhook update.
- [x] 3.3 Drop the originally planned `MultiChannelTrialLive`; onboarding now demonstrates the multichannel path.
- [x] 3.4 Implement `DripdropDemoWeb.Scenarios.OutboundLive` at `/scenarios/outbound`: cold outbound email thread for Elixir/Phoenix/LiveView consulting with multiple recipients, sequence code mirror, message stream, and runtime logs.
- [x] 3.5 Keep the three scenario UIs consistent: sequence steps/code on the left, sequence messages on the right, runtime logs below.
- [x] 3.6 Render outbound email previews in the scenario UI; do not rely on `/dev/mailbox`.
- [x] 3.7 Use shared scenario components for sequence flipper, webhook/code rendering, message cards, and runtime logs.
- [x] 3.8 Each scenario LiveView lives in its own directory `demo/lib/dripdrop_demo_web/live/scenarios/<name>/` with its own `index.html.heex`.
- [x] 3.10 Implement `DripdropDemoWeb.Live.PubSubBridge` (or similar) — a small GenServer that listens to `[:dripdrop, :dispatch, ...]`, `[:dripdrop, :enrollment, ...]`, `[:dripdrop, :health, ...]`, and `[:dripdrop, :policy, ...]` telemetry and republishes to scenario-specific Phoenix.PubSub topics so the LiveViews can subscribe. Document the bridge in `demo/README.md`.

## 4. Dashboard scope

- [x] 4.1 Keep Phoenix LiveDashboard mounted at `/phx-dashboard` in dev/test.
- [x] 4.2 Defer DripDrop dashboard surfaces to a future dashboard change.

## 5. Seed task

- [x] 5.1 Implement `demo/priv/repo/seeds.exs` (run via `mix demo.seed`) for local/sandboxed adapters, the onboarding, lead nurture, and outbound sequences, mock HTTP hooks, and fixture data. Persist short demo delays directly as normal DripDrop timing values.
- [x] 5.2 Wire `mix demo.seed` alias in `demo/mix.exs`. Verify `mix demo.seed && mix demo.seed` exits 0 with no duplicate rows. Add `mix demo.reset` alias as `["ecto.reset", "demo.seed"]` for the documented "stuck demo" recovery path.
- [x] 5.3 Document `mix ecto.reset && mix demo.seed` as the canonical reset workflow in `demo/README.md`.

## 6. Documentation

- [x] 6.1 Author `demo/README.md` documenting the run loop, scenario URLs (`/scenarios/onboarding`, `/scenarios/lead-nurture`, `/scenarios/outbound`), local ports, production-safe mocked channels, timing, and useful commands.
- [x] 6.2 Document the path-dep development loop after pulling library changes; the demo always rebuilds against the working copy.
- [x] 6.3 Add a concise "Common pitfalls" section to `demo/README.md`: stale compiled artifacts and Postgres port collisions with other DripDrop forks.
- [x] 6.4 Link `demo/README.md` from the top-level `README.md` (small edit; one line under the existing "Quick Start" section).

## 7. CI integration — removed from scope

Demo-side CI is intentionally not run as a separate matrix entry. Demo
quality and tests run locally via `mix quality` and `mix test` in `demo/`;
operator smoke testing is sufficient for this scenario reference app.

## 8. Tests

- [x] 8.1 Demo-side ExUnit tests under `demo/test/`: each scenario LiveView has a smoke test that enrolls a fixture and asserts the first step transitions through the documented states.
- [x] 8.2 Mock-hooks tests: assert deterministic responses for `/lead-score` and `/crm-update`.
- [x] 8.3 ~~Phoenix LiveDashboard route smoke test for `/phx-dashboard` in dev/test.~~ Removed from scope; LiveDashboard is unmodified Phoenix infrastructure.
- [x] 8.4 Seed idempotency test: run seeds twice in a fresh test database, assert no duplicates (including the outbound_pool and its three members). Lives at `test/dripdrop_demo/seeds_test.exs` — 3 tests cover snapshot equality, the 3-member pool invariant, and one-row-per-sequence-key.
- [x] 8.5 `OutboundLive` LiveView test: render the page, click the "Outbound Campaign" button to enroll 8 prospects, assert each prospect renders in the 8-card grid by name, assert the sender pool panel renders, assert simulator outcomes can be triggered (e.g., Eli → hard bounce produces a `MessageEvent` and `Suppression`), assert PubSub `:health` events refresh the sender pool panel, and assert the Reset capacity flow produces a fresh `0/<daily_cap>` capacity bar. (The original spec text mentioned cycling through recipients via chevrons; that cycler was replaced by the 8-card grid in the post-MVP enhancement.)

## 9. Production delivery boundary

- [x] 9.1 Demo uses local/sandboxed delivery for production-safe presentation. Real deliverability testing belongs to provider integration tests or host-app release validation, not this demo UI.

## 10. Validation and release

- [x] 10.1 Run `openspec validate add-dripdrop-demo-app --strict` — must pass.
- [x] 10.2 Run `mix quality` from `demo/` — must pass.
- [x] 10.3 Run `mix test` from `demo/` — must pass. (20 tests, 0 failures as of 2026-05-10.)
- [x] 10.4 ~~Run `mix dialyzer` from `demo/` (with demo-owned PLT per design Q1) — no warnings.~~ Removed from scope; `mix quality` (compile/format/sobelow/ex_dna/doctor/credo --strict) is sufficient gate for the demo.
- [x] 10.5 ~~Run `make ci-demo` end-to-end locally to confirm the CI step works.~~ Removed; CI scope dropped (see §7).
- [x] 10.6 Confirm manual deliverability smoke is no longer part of this demo scope.
- [x] 10.7 Update top-level `README.md` to link to `demo/README.md` (task 6.4 covered this; final verification step here).
- [ ] 10.8 Tag this change as ready-to-archive after merge: `openspec archive add-dripdrop-demo-app`.

## 11. Post-MVP outbound demo enhancements (added 2026-05-10)

Built and merged after the foundation tasks above; not in original scope but
shipped together because they make the outbound scenario demo-grade.

- [x] 11.1 Add `DripdropDemo.Scenarios.Outbound.Outcomes` mapping each of the 8 prospect first names to one of `:ghost | :reply_positive | :reply_ooo | :hard_bounce | :soft_bounce | :unsubscribe | :ramp_cap | :rest_pinned_sender`. Single source of truth via `for_first_name/1` and a compile-time `MapSet` for `valid?/1`.
- [x] 11.2 Add `DripdropDemo.Scenarios.Outbound.Simulators` wrapping `DripDrop.ingest_inbound_message/2`, `DripDrop.suppress/1`, `DripDrop.set_adapter_health/2`, direct `MessageEvent` insert (for hard/soft bounce), and synthetic `dispatch_next/1` invocations behind a uniform `trigger/2` entry point. LiveView never touches `MessageEvent` rows or library private APIs directly.
- [x] 11.3 Add `DripdropDemoWeb.OutboundComponents` (outbound-only widgets so `scenario_components.ex` stays generic): `outcome_badge`, `sender_pool_panel`, `sender_health_pill`, `capacity_bar`, `min_gap_meter`, `defer_reason_badge`, `pin_breadcrumb`, `prospect_card`, `sender_control_strip`, `countdown_pill`.
- [x] 11.4 Replace the recipient cycler with an 8-card grid (`grid grid-cols-2 lg:grid-cols-4`) in `OutboundLive`. Each card composes outcome badge + pin breadcrumb + outcome description; click selects the prospect and drives the existing thread detail pane below.
- [x] 11.5 Render a sender pool panel above the prospect grid showing per-sender health pill, capacity bar (`sent_today / effective_cap_today`), min-gap meter, and a Rest/Probe/Activate control strip.
- [x] 11.6 `OutboundLive` auto-play: on `[:dripdrop, :dispatch, :sent]` for `consulting-intro`, schedule `:autoplay_outcome` per enrollment with jitter via `Process.send_after/3`. Triggered ids tracked in a `MapSet` to prevent re-fires.
- [x] 11.7 `Outbound.reset_capacity_today/0` operator helper: backdates today's `MessageEvent` `sent` rows out of the day and restores adapter caps from `Outbound.daily_cap_default/0` + `Outbound.min_gap_default/0` (centralized as module attributes with public getters; the api_mirror_snippet display string and seed comment also reference these defaults).
- [x] 11.8 Outbound context projections extended: `enrollment_row` adds `adapter_provider`, `sender_email`, `outcome`, `last_defer`; `pool_member_row` adds `provider`, `sender_email`, `effective_cap_today`, `last_send_at`, `paused_until`, `paused_reason` (read from `adapter.config["paused_until"]` JSONB).
- [x] 11.9 `OutboundLive` PubSub fan-out: subscribes to per-adapter `adapter:<id>` topics so health/policy events without `enrollment_id` metadata still refresh the pool panel.
- [x] 11.10 Performance pass on `:tick` handler — clock-only update; mount pool query deferred to connected phase; `Outcomes.valid?/1` precomputed as `MapSet`. Simulator `with` clauses use explicit `:ok | {:error, reason}` helpers (`fetch_enrollment/1`, `validate_outcome/1`).
- [x] 11.11 `data-enrollment-id` attribute on prospect cards; LiveView test uses Floki to find enrollments by name instead of `:sys.get_state(view.pid)`.
- [x] 11.12 Test fixture `DripdropDemo.Test.OutboundFixture.seed_outbound_minimal/0` replaces `Code.eval_file("priv/repo/seeds.exs")` per test for outbound LiveView tests; mirrors the canonical seed shape but omits onboarding + lead-nurture for speed.
- [x] 11.13 New simulator unit tests at `test/dripdrop_demo/scenarios/outbound/simulators_test.exs` (9 tests covering each outcome atom).

## 12. Public-demo lifecycle (added 2026-05-10)

Out-of-scope addition that supports running the demo as a public hosted app
without unbounded data growth.

- [x] 12.1 New `DripdropDemo.Jobs.PruneSequenceRuns` PgFlow job: nightly cron at `0 3 * * *` deletes completed/cancelled enrollments older than 24 hours for the demo tenant + the three demo sequences, cascading through `message_events`, `short_links`, `events`, `step_executions`. Calls `PgFlow.Queries.Flows.prune_data/3` afterward to clean PgFlow runtime data. Sequence definitions, versions, steps, transitions, hooks, adapters, and pools are preserved.
- [x] 12.2 Migration `20260510152736_compile_prune_sequence_runs.exs` registers the job in PgFlow with the cron schedule. Application supervisor includes `PruneSequenceRuns` alongside `DispatchStep` and `CronTick` jobs.
- [x] 12.3 `prune_dripdrop_runtime/2` retention is configurable via `Application.get_env(:dripdrop_demo, :sequence_run_retention_hours, 24)`.
- [x] 12.4 Comprehensive test at `test/dripdrop_demo/jobs/prune_sequence_runs_test.exs` using SQL CTE fixture builders to assert old completed demo runs are pruned but fresh, active, and non-demo sequences are preserved.
