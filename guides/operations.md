# Operations

## Startup Checks

Call `DripDrop.startup_check/0` during host boot. The check validates channel
configuration, optional provider dependencies, encryption key decoding,
scheduler callbacks, unsubscribe URL builder requirements, and PgFlow job
registration when `DripDrop.Schedulers.Pgflow` is configured.

## Schema Checks

Run:

```bash
mix dripdrop.check_schema
```

Use this in CI and deploy smoke checks.

## Integration Tests

Integration tests exercise the real PgFlow scheduler, worker polling, webhook
ingest, and database state transitions. Provider HTTP calls stay local through
`Req.Test`; tests must not call real provider networks.

Run them locally after the test database is up:

```bash
docker compose up -d
mix test --only integration
```

Add new integration tests with `DripDrop.IntegrationCase` and
`@moduletag :integration`. Use `DripDrop.TestSupport.PgflowHarness` when a test
needs a PgFlow worker, and prefer `eventually/2` over fixed sleeps for state
that changes in worker processes.

When debugging PgFlow timing flakes:

- Lower `min_poll_interval` / `max_poll_interval` in `PgflowHarness.child_spec/1`.
- Increase the relevant `eventually/2` timeout before adding sleeps.
- Inspect `pgflow.step_tasks`, `pgflow.runs`, and `pgmq.q_dispatch_step` to see
  whether work is queued, started, failed, or invisible due to retry delay.
- Keep provider stubs in `Req.Test` shared mode when the request is made from a
  PgFlow worker process.

## Telemetry

Attach handlers to `DripDrop.Telemetry.events/0` for dispatch, policy,
provider ingest, template, hook, short-link, and channel events.

```elixir
:telemetry.attach_many(
  "dripdrop-ops",
  DripDrop.Telemetry.events(),
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

## Provider Events

`DripDrop.Web.WebhookPlug` verifies provider signatures before normalization.
Duplicate provider events skip duplicate persistence and emit telemetry.
Duplicate replies can still run configured reply handling.

## Uninstall

Generate the uninstall SQL:

```bash
mix dripdrop.uninstall
```

The task prints the destructive SQL for an operator to review; it does not drop
the schema automatically.
