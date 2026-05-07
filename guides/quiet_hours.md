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
* `config :dripdrop, :default_timezone`, defaulting to `"Etc/UTC"`

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
