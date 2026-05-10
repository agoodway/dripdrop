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

## 7. CI integration

- [ ] 7.1 Add `make ci-demo` (or equivalent shell script) that runs `docker compose up -d`, waits for Postgres readiness, `cd demo`, `mix setup`, `mix demo.seed`, `mix test`, `mix quality`. Idempotent and safe to run repeatedly.
- [ ] 7.2 Add a new GitHub Actions matrix entry that runs `make ci-demo` on PRs touching `demo/**` or on release-tagged commits. Library-only PRs SHALL NOT trigger this entry.
- [ ] 7.3 Keep demo CI independent from library-only CI so Phoenix/demo churn does not block unrelated library changes.

## 8. Tests

- [ ] 8.1 Demo-side ExUnit tests under `demo/test/`: each scenario LiveView has a smoke test that enrolls a fixture and asserts the first step transitions through the documented states.
- [ ] 8.2 Mock-hooks tests: assert deterministic responses for `/lead-score` and `/crm-update`.
- [ ] 8.3 Phoenix LiveDashboard route smoke test for `/phx-dashboard` in dev/test.
- [ ] 8.4 Seed idempotency test: run seeds twice in a fresh test database, assert no duplicates (including the cold_drip_pool and its three members).
- [ ] 8.5 `OutboundLive` LiveView test: enroll 8 prospects, assert WDRR distributes pinned `adapter_id` values across all three pool members (≥1 each over 8 enrollments), and assert the threaded email preview can cycle through recipients.

## 9. Production delivery boundary

- [x] 9.1 Demo uses local/sandboxed delivery for production-safe presentation. Real deliverability testing belongs to provider integration tests or host-app release validation, not this demo UI.

## 10. Validation and release

- [x] 10.1 Run `openspec validate add-dripdrop-demo-app --strict` — must pass.
- [x] 10.2 Run `mix quality` from `demo/` — must pass.
- [ ] 10.3 Run `mix test` from `demo/` — must pass.
- [ ] 10.4 Run `mix dialyzer` from `demo/` (with demo-owned PLT per design Q1) — no warnings.
- [ ] 10.5 Run `make ci-demo` end-to-end locally to confirm the CI step works.
- [x] 10.6 Confirm manual deliverability smoke is no longer part of this demo scope.
- [x] 10.7 Update top-level `README.md` to link to `demo/README.md` (task 6.4 covered this; final verification step here).
- [ ] 10.8 Tag this change as ready-to-archive after merge: `openspec archive add-dripdrop-demo-app`.
