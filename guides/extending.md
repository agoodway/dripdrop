# Extending DripDrop

DripDrop extension points are Elixir modules with small behaviours or
registration APIs.

## Custom Channel Provider

Implement `DripDrop.Channel`:

```elixir
defmodule MyApp.Channels.Resend do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, adapter), do: {:ok, %{provider_message_id: "..."}}
  def validate_credentials(credentials), do: :ok
  def webhook_routes(_adapter), do: []
  def verify_signature(_adapter, _request), do: :ok
end
```

Register it at boot:

```elixir
DripDrop.Channels.register(:email, :resend, MyApp.Channels.Resend)
```

## Adding A New Email Provider

1. Choose the delivery path: use a Swoosh adapter when one exists, otherwise
   call the provider API directly with Req.
2. Implement `validate_credentials/1` with cheap local validation and optional
   provider verification.
3. Add `verify_signature/2` and `webhook_routes/1` only when the provider sends
   signed delivery webhooks.
4. Register the provider with `DripDrop.Channels.register/3`.

Use `DripDrop.Channels.Email.SwooshDelivery` for Swoosh-backed providers so
payload mapping and error taxonomy stay consistent.

## Custom Short-Link Adapter

Implement `DripDrop.ShortLinks.Adapter`:

```elixir
defmodule MyApp.ShortLinks do
  @behaviour DripDrop.ShortLinks.Adapter

  alias DripDrop.ShortLinks.Result

  def create_link(request, opts) do
    {:ok,
     %Result{
       short_url: "https://s.example/abc",
       provider_id: request.idempotency_key,
       response: %{original_url: request.original_url, opts: opts}
     }}
  end
end
```

## Custom Scheduler

Implement `DripDrop.Scheduler` when PgFlow or Oban is not the right runtime.
The callbacks are `schedule(execution, scheduled_for)` and `cancel(job_id)`.
Schedulers should enqueue durable work from the `StepExecution` record rather
than embedding rendered payloads.

## Custom Hook Module

Sequence hooks call a host module through `DripDrop.HookBehavior`:

```elixir
defmodule MyApp.DripDropHooks do
  @behaviour DripDrop.HookBehavior

  def handle_hook(:score_lead, enrollment, context) do
    {:ok, get_in(enrollment.data, ["score"]) || context[:default_score]}
  end
end
```

## Choosing a Condition Type

Conditions on steps and transitions come in two evaluation flavors. They look
similar but use different comparison semantics on purpose — pick by the shape
of the rule you need to express, not by personal preference.

### `enrollment_data`, `hook`, and `event` — coercive comparator

These types take a `(field_path, operator, expected_value)` triple. Operators
match the Predicated DSL vocabulary: `==`, `!=`, `contains`, `in`, `>`, `>=`,
`<`, `<=`. The comparator coerces both sides with `to_string/1` for the
equality operators, and uses `Float.parse/1` for the numeric ones, so
`expected_value: "5"` matches enrollment data of integer `5` or string `"5"`
identically.

Use this for the common case: one field, one operator, one expected value.
Compose with `transition.condition_mode = "all"` or `"any"` when you need
multiple conditions to fire together.

```elixir
%{
  condition_type: "enrollment_data",
  field_path: "trial_days_remaining",
  operator: "<",
  expected_value: "3"
}
```

### `predicate` — typed DSL

The `predicate` type stores a Predicated expression in `config["predicate"]`.
It supports `and`, `or`, parentheses, and types are compared strictly (an
integer field against a string literal will not match — quote string literals,
leave numeric literals unquoted).

Use this when you need compound boolean logic with grouping, e.g.
`(A and B) or (C and D)`, that a single `condition_mode` can't express.

```elixir
%{
  condition_type: "predicate",
  config: %{
    "predicate" =>
      "(plan == 'pro' and trial_days_remaining > 0) or has_paid_invoice == true"
  }
}
```

### Why two evaluators

The two paths are kept deliberate: `enrollment_data` is forgiving for simple
rules, `predicate` is precise for advanced authoring. They cannot be merged
without changing observable behavior — a typed comparison would silently flip
an `expected_value: "5"` rule today.
