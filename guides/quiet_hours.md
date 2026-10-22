# Quiet Hours

Quiet hours defer dispatch based on the recipient's local time. DripDrop leans
on Postgres timezone functions so the decision is made consistently with the
database clock.

## Timezone Resolution

DripDrop resolves the timezone in this order:

* `enrollment.data["timezone"]`
* `step.config["timezone"]`
* `config :dripdrop, :quiet_hours_timezones`, keyed by channel
* sequence metadata `"default_timezone"` or `"timezone"`
* `config :dripdrop, :tenant_timezone_resolver`, called with the enrollment's
  `tenant_key`
* `config :dripdrop, :default_timezone`, defaulting to `"Etc/UTC"`

## Tenant Timezone Resolver

When a tenant's timezone lives in the host application, configure a resolver
instead of copying it into every enrollment or sequence. DripDrop calls it at
dispatch time, so a tenant that changes its timezone gets the new zone for
executions that are already scheduled.

```elixir
config :dripdrop, :tenant_timezone_resolver, {MyApp.Accounts, :tenant_time_zone}
```

The resolver is a `{module, function}` or `{module, function, extra_args}`
tuple, or a one-arity function. It receives the tenant key first, followed by
any extra arguments, and returns an IANA timezone string or `nil`. `nil` falls
through to `:default_timezone`. Any other return value fails the step
permanently with `{:invalid_tenant_timezone, value}`, and an unknown zone name
fails it with `{:quiet_hours_timezone, zone, reason}`. The resolver runs only
when the enrollment, step, channel, and sequence name no timezone, so a
per-enrollment `"timezone"` still overrides it.

The application quiet-hours default is `{8, 21}` for every channel unless a
step overrides it or sets `"quiet_hours" => false`.

## Step Configuration

```elixir
%{
  "quiet_hours" => %{
    "start" => 8,
    "end" => 21
  },
  "timezone" => "America/New_York"
}
```

The end hour is exclusive, so `{8, 21}` allows sends from 8:00 through 20:59 in
the resolved timezone. Windows can wrap midnight. When a send is outside the
allowed window, the dispatch worker returns a deferral time and emits
`[:dripdrop, :policy, :quiet_hours]`.
