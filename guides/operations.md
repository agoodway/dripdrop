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
