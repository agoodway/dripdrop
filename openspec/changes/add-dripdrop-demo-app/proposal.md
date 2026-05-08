## Why

DripDrop's `add-dripdrop-foundation` change originally bundled a Phoenix demo application alongside the library itself. As implementation progressed it became clear that the demo's scope (Phoenix 1.8 + LiveView 1.1 app, three scenario LiveViews, read-only dashboard, seed fixtures, `mix demo.seed`, `demo/README.md`, demo-side `mix quality` alias) is independently shippable and shouldn't gate the library's `v0.1.0`. Pulling the demo out into its own change unblocks foundation archive, simplifies foundation's CI/release surface, and lets the demo evolve at its own pace.

The library is still useful and complete without the demo — host applications adopt DripDrop by following `guides/installation.md` against their own Phoenix or non-Phoenix repo. The demo exists to give *first-time* operators a runnable end-to-end reference and to validate that the foundation public API actually composes the way the library README claims. Both goals are valuable but neither is on the critical path for v0.1.0.

## What Changes

- New change `add-dripdrop-demo-app` introducing the `demo-app` capability previously declared (but not yet implemented) inside `add-dripdrop-foundation`.
- Demo lives at `demo/` (sibling to `lib/`) with `{:dripdrop, path: ".."}` in its `mix.exs`. Library's own `package:` continues to exclude `demo/` from Hex (already enforced by foundation task 1.2).
- Three scenario LiveViews mirroring the README examples — `OnboardingLive`, `LeadNurtureLive`, `MultiChannelTrialLive`. Each enrolls a fixture subscriber, subscribes to PubSub for that enrollment, and renders live state transitions as dispatch progresses.
- Read-only dashboard at `/dashboard/*` with four LiveViews (sequences / enrollments / executions / message_events). Cursor-paginated. **No** create / update / delete. The full editable dashboard is explicitly deferred to a future `add-dripdrop-dashboard` change.
- `Phoenix.LiveDashboard` mounted at `/phx-dashboard` for OTP introspection.
- `mix demo.seed` — idempotent seed task creating one email adapter (Mailgun-sandbox or local Mailpit), one SMS adapter (Twilio test SID), the three sequences with their steps/transitions/conditions, fixture subscribers, and one HTTP hook pointing at a local mock server.
- `demo/lib/dripdrop_demo/mock_hooks.ex` — small in-process Bypass-style HTTP server so the LeadNurtureLive scenario runs offline without external dependencies.
- Demo `Endpoint` mounts `DripDrop.Web.Router.dripdrop_webhooks("/webhooks/dripdrop")` and `DripDrop.Web.UnsubscribePlug` at `/u/:token`. Configures `unsubscribe_url_builder` and `unsubscribe_secret` so RFC 8058 round-trip works locally.
- Demo `mix.exs` defines its own `quality` alias mirroring the library's (`compile --warnings-as-errors`, `format --check-formatted`, `sobelow`, `ex_dna`, `doctor`, `credo --strict`) — re-enables what foundation task 15.2 had to pause.
- `demo/README.md` documenting prerequisites, `docker compose up -d` from the repo root (uses foundation's existing `Dockerfile`/`docker-compose.yml`), `mix setup`, `mix demo.seed`, `mix phx.server`, scenario URLs, dashboard URLs, and the offline / no-Docker fallback path.
- CI smoke test (`make ci-demo` or equivalent) running `docker compose up -d`, `cd demo && mix setup && mix demo.seed && mix test` to confirm the demo's own tests pass.
- Manual deliverability smoke from the demo: enroll a fixture subscriber whose email is a mailbox you control, dispatch a real Mailgun-sandbox sequence of 25 messages from a warmed sender; verify SPF/DKIM/DMARC pass, optional List-Unsubscribe headers are present in Gmail's "Show original", and one-click POST to the demo's `/u/:token` writes a suppression row.
- Top-level `README.md` link to `demo/README.md` (small follow-on edit; not in foundation's release tasks).

## Capabilities

### New Capabilities

- `demo-app`: Phoenix 1.8 + LiveView 1.1 application living at `demo/` that consumes `:dripdrop` as a path dep and exercises the library end-to-end. Owns: scenario LiveViews mirroring the README examples, read-only in-app dashboard, `mix demo.seed` fixtures, mock HTTP-hook endpoint, webhook ingest + unsubscribe wiring, demo-side `mix quality` alias, demo `README.md`. Does NOT own the top-level `Dockerfile`/`docker-compose.yml` (those are library infrastructure already shipped by foundation tasks 1.7/1.8) — the demo simply *uses* them. Does NOT own the editable dashboard (deferred to `add-dripdrop-dashboard`).

### Modified Capabilities

(none — the foundation change has been edited to remove its previous declaration of `demo-app` since foundation has not yet archived; this change introduces the capability as new.)

## Impact

- **Code**: New `demo/` Phoenix LiveView app at the repo root (path-dep on `..`). New scenario LiveViews under `demo/lib/dripdrop_demo_web/live/scenarios/`. New dashboard LiveViews under `demo/lib/dripdrop_demo_web/live/dashboard/`. New `demo/lib/dripdrop_demo/mock_hooks.ex` Bypass-style HTTP-hook server. New `demo/priv/repo/seeds.exs` with idempotent fixture loading. New `demo/README.md`.
- **APIs**: No new public API on the library. The demo consumes the existing `DripDrop.*` API surface defined by foundation. If the demo discovers gaps in the public API or guides during implementation, those become foundation-side fixes (or follow-on changes), not demo-side workarounds.
- **Database**: No schema changes. The demo runs against the same `dripdrop` Postgres schema introduced by foundation's V01 migration.
- **Dependencies**: New (demo-side `mix.exs` only): `phoenix ~> 1.8`, `phoenix_live_view ~> 1.1`, `phoenix_live_dashboard ~> 0.8`, `phoenix_pubsub ~> 2.1`, `bypass ~> 2.1` (for mock_hooks), plus the same quality dev deps the library uses (`credo`, `dialyxir`, `sobelow`, `doctor`, `ex_dna`). Library `mix.exs` is unchanged.
- **Repo-root assets**: Used but not authored by this change — the existing `Dockerfile`, `docker-compose.yml`, and library `mix.exs` (which excludes `demo/` from Hex) are foundation work already complete.
- **Host-app responsibilities**: None. The demo is a self-contained operator-facing reference, not something host apps depend on.
- **Operational**: New CI matrix entry running the demo's quality + tests. New manual deliverability smoke step in the release checklist (see `add-dripdrop-foundation` for library-level release; demo deliverability smoke is owned here).
- **Out of scope for this change**:
  - Outbound-mode demo scenario (4th scenario `OutboundLive`). Depends on `add-cold-outbound-mode` being archived. Will be added by a small follow-on change after both foundation and cold-outbound have shipped.
  - Editable dashboard with create / update / delete actions. Deferred to `add-dripdrop-dashboard`.
  - Demo deployment / hosting (`fly.io` / similar). The demo is a local-development tool; hosting it publicly is out of scope.
  - Production-grade auth or multi-tenancy in the demo's UI. The demo runs single-tenant against `tenant_key: nil` fixtures.
