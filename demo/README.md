# DripDrop Demo

Phoenix host app for exercising DripDrop end to end.

## Run

The repo root includes the same Hivemind wrapper style used by the sibling
Elixir demo apps:

```sh
../bin/dripdrop start
../bin/dripdrop stop
../bin/dripdrop console
```

Or run the Phoenix app directly:

```sh
mix setup
mix demo.seed
mix phx.server
```

Then open <http://localhost:4012>.

The demo uses PostgreSQL on port `54325` with `dripdrop_dev`, local/sandboxed
email, SMS, Telegram, and webhook providers, Phoenix PubSub, and a demo-only
mock webhook server on port `4013`. PubSub dispatches locally; other external
channels are rendered or mocked for a production-safe demo.

## Scenarios

- `/scenarios/onboarding` — welcome email, in-app nudge, HTTP setup-status
  check, SMS follow-up, and Telegram team update.
- `/scenarios/lead-nurture` — email verification hook, lead scoring webhook,
  branch decisions, nurture email, sales alert, and CRM webhook update.
- `/scenarios/outbound` — outbound email thread for Elixir, Phoenix, and
  LiveView consulting services with multiple recipients and sender-pool
  behavior.

The demo app uses the same DripDrop APIs a host app would use. PgFlow and
DripDrop schemas/jobs are installed once through migrations; scenario sequences
are seeded dynamically through DripDrop sequence-authoring calls.

## Timing

Demo timings are intentionally short so multi-step sequences play out in
seconds. The persisted timings are regular DripDrop delay values; no special
scheduler exists for the demo.

## Telemetry → PubSub Bridge

`DripdropDemoWeb.PubSubBridge` is a small GenServer in the supervision tree
(not under `live/`) that attaches a single `:telemetry` handler to every event
in `DripDrop.Telemetry.events/0` and rebroadcasts each one through
`DripdropDemo.PubSub` on three topic shapes:

- `dripdrop:events` — global firehose; LiveViews subscribe here.
- `enrollment:<id>` — when the event metadata carries `enrollment_id`.
- `adapter:<id>` — when the event metadata carries `adapter_id`.

Telemetry handlers run in the *emitting* process (a PgFlow worker, not the
GenServer), so the bridge wraps its handler body in `try/rescue` with
stacktrace logging — a future schema change cannot kill an emitter process.

## Reset Workflow

If the demo gets into a confused state (stale data, half-migrated schema,
sequences stuck mid-flow), the canonical reset is:

```sh
mix ecto.reset && mix demo.seed
```

`mix ecto.reset` drops the database, recreates it, and re-runs every PgFlow
and DripDrop migration. `mix demo.seed` re-installs the three demo
sequences (User Onboarding, Lead Nurture, Outbound Campaigns) along with
their channel adapters, hooks, sender pool, and pool members. The combined
shortcut alias is also available:

```sh
mix demo.reset
```

## Path-dep Development Loop

The demo declares the library as `{:dripdrop, path: ".."}`. After pulling
new library changes the demo always rebuilds against the working copy:

```sh
git pull           # in repo root
cd demo
mix deps.compile dripdrop --force   # only if Elixir cached the old build
mix phx.server
```

The `--force` recompile is rarely needed — Elixir notices source changes in
the path dep automatically — but stale `_build/` artifacts after a major
library refactor can be the difference between "weird crash on boot" and
"working demo." When in doubt, `rm -rf _build` and re-run `mix phx.server`.

## Common Pitfalls

- **Stale compiled artifacts after a library refactor.** If the demo crashes
  at boot with a function or module that doesn't match the library's current
  source, run `rm -rf _build deps/dripdrop` and `mix deps.get` from the demo
  directory. The path-dep build cache is the most common culprit.
- **Postgres port collisions with other DripDrop forks.** The demo binds to
  `localhost:54325`. If you're running another DripDrop checkout (or any other
  `docker compose`-based Postgres on the same port) the demo will silently
  connect to the wrong database. Stop the other container or change
  `port:` in `demo/config/dev.exs` before booting.

## Useful Commands

```sh
mix ecto.reset
mix demo.seed
mix demo.reset      # ecto.reset + demo.seed
mix quality
mix test
```
