## Why

DripDrop's `add-dripdrop-foundation` change originally bundled a Phoenix demo application alongside the library itself. As implementation progressed it became clear that the demo's scope (Phoenix 1.8 + LiveView 1.1 app, scenario LiveViews, seed fixtures, `mix demo.seed`, `demo/README.md`, demo-side `mix quality` alias) is independently shippable and shouldn't gate the library's `v0.1.0`. Pulling the demo out into its own change unblocks foundation archive, simplifies foundation's CI/release surface, and lets the demo evolve at its own pace.

The library is still useful and complete without the demo — host applications adopt DripDrop by following `guides/installation.md` against their own Phoenix or non-Phoenix repo. The demo exists to give *first-time* operators a runnable end-to-end reference and to validate that the foundation and cold-outbound public API surfaces actually compose the way the library README claims. Both goals are valuable but neither is on the critical path for v0.1.0.

`add-cold-outbound-mode` has now archived (commit `ec6e8c3`), so the cold-drip scenario that used to be deferred is in scope here: the demo is the first place a cold-outbound operator can observe sender-pool selection, pinned recipients, and threaded email delivery without writing host-app glue.

## What Changes

- New change `add-dripdrop-demo-app` introducing the `demo-app` capability previously declared (but not yet implemented) inside `add-dripdrop-foundation`.
- Demo lives at `demo/` (sibling to `lib/`) with `{:dripdrop, path: ".."}` in its `mix.exs`. Library's own `package:` continues to exclude `demo/` from Hex (already enforced by foundation task 1.2).
- Three scenario LiveViews — `OnboardingLive`, `LeadNurtureLive`, and `OutboundLive` — share the same demo UI pattern: sequence steps/code on the left, delivered sequence messages on the right, and runtime logs below.
- `OnboardingLive` demonstrates welcome email, in-app PubSub nudge, HTTP setup-status check, SMS follow-up, and Telegram team update.
- `LeadNurtureLive` demonstrates an Elixir email-verification hook, HTTP lead-scoring webhook, predicate branching, nurture email, PubSub sales alert, and CRM webhook update.
- `OutboundLive` demonstrates a cold outbound email thread for Elixir, Phoenix, and LiveView consulting services with multiple recipients and sender-pool behavior.
- Demo timings are short so sequences play out in seconds. The library scheduler is unchanged; persisted timings are normal DripDrop delay values.
- `mix demo.seed` — idempotent seed task creating local/sandboxed adapters, the three sequences with their steps/transitions/conditions, fixture subscribers, and mock HTTP hooks.
- `demo/lib/dripdrop_demo/mock_hooks.ex` — small in-process Bypass-style HTTP server so the LeadNurtureLive scenario runs offline without external dependencies.
- Demo `Endpoint` mounts `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token`. Configures `unsubscribe_url_builder` and `unsubscribe_secret` so RFC 8058 round-trip works locally.
- Demo `mix.exs` defines its own `quality` alias mirroring the library's (`compile --warnings-as-errors`, `format --check-formatted`, `sobelow`, `ex_dna`, `doctor`, `credo --strict`) — re-enables what foundation task 15.2 had to pause.
- `demo/README.md` documenting the run loop, local ports, scenario URLs, `/phx-dashboard`, production-safe mocked delivery, short demo timing, and useful commands.
- CI smoke test (`make ci-demo` or equivalent) running `docker compose up -d`, `cd demo && mix setup && mix demo.seed && mix test` to confirm the demo's own tests pass.
- Production delivery smoke is out of scope for the demo UI; provider deliverability belongs in host-app release validation or provider integration tests.
- Top-level `README.md` link to `demo/README.md` (small follow-on edit; not in foundation's release tasks).

## Capabilities

### New Capabilities

- `demo-app`: Phoenix 1.8 + LiveView 1.1 application living at `demo/` that consumes `:dripdrop` as a path dep and exercises the library end-to-end. Owns: three scenario LiveViews, `mix demo.seed` fixtures, mock HTTP-hook endpoint, webhook ingest + unsubscribe wiring, demo-side `mix quality` alias, and demo `README.md`. Does NOT own the top-level `Dockerfile`/`docker-compose.yml` (those are library infrastructure already shipped by foundation tasks 1.7/1.8) — the demo simply uses them.

### Modified Capabilities

(none — the foundation change has been edited to remove its previous declaration of `demo-app` since foundation has not yet archived; this change introduces the capability as new.)

## Impact

- **Code**: New `demo/` Phoenix LiveView app at the repo root (path-dep on `..`). New scenario LiveViews under `demo/lib/dripdrop_demo_web/live/scenarios/`. New `demo/lib/dripdrop_demo/mock_hooks.ex` HTTP-hook server. New `demo/priv/repo/seeds.exs` with idempotent fixture loading. New `demo/README.md`.
- **APIs**: No new public API on the library. The demo consumes the existing `DripDrop.*` API surface defined by foundation. If the demo discovers gaps in the public API or guides during implementation, those become foundation-side fixes (or follow-on changes), not demo-side workarounds.
- **Database**: No schema changes. The demo runs against the same `dripdrop` Postgres schema introduced by foundation's V01 migration.
- **Dependencies**: New (demo-side `mix.exs` only): `phoenix ~> 1.8`, `phoenix_live_view ~> 1.1`, `phoenix_live_dashboard ~> 0.8`, `phoenix_pubsub ~> 2.1`, `bypass ~> 2.1` (for mock_hooks), plus the same quality dev deps the library uses (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`). Library `mix.exs` is unchanged.
- **Repo-root assets**: Used but not authored by this change — the existing `Dockerfile`, `docker-compose.yml`, and library `mix.exs` (which excludes `demo/` from Hex) are foundation work already complete.
- **Host-app responsibilities**: None. The demo is a self-contained operator-facing reference, not something host apps depend on.
- **Operational**: New CI matrix entry running the demo's quality + tests.
- **Out of scope for this change**:
  - Editable dashboard with create / update / delete actions. Deferred to `add-dripdrop-dashboard`.
  - Demo deployment / hosting (`fly.io` / similar). The demo is a local-development tool; hosting it publicly is out of scope.
  - Production-grade auth or multi-tenancy in the demo's UI. The demo runs single-tenant against `tenant_key: nil` fixtures.
  - Real IMAP/Gmail-API/Microsoft-Graph reply polling. Wiring a real reply poller is out of scope and would belong in a future host-app integration guide.
  - Real adapter warmup / postmaster-tools telemetry. The cold outbound scenario uses fixture senders and rendered messages; production hosts wire real telemetry and providers.
