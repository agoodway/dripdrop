# Sending Rules

DripDrop uses explicit policy flags instead of broad mode labels. Each sequence
step can opt into the rules it needs.

## Unsubscribe Headers

Email steps can opt into RFC 8058 headers:

```elixir
%{
  "unsubscribe_headers" => true
}
```

or:

```elixir
%{
  "unsubscribe" => true
}
```

When enabled, configure `:unsubscribe_url_builder` so the host app can return a
one-click unsubscribe URL. DripDrop inserts the RFC 8058 headers before
provider delivery.

## Reply Behavior

Replies are recorded as provider events by default. To pause an enrollment after
a reply:

```elixir
%{
  "reply_behavior" => "pause_enrollment"
}
```

Hosts can replace the default behavior with `config :dripdrop, :on_reply`.
The callback can be a `{Module, :function}` pair or an arity-2 function called
with the normalized event and step execution.

## Recipient Verification

To require the host app to mark a recipient as verified before a send:

```elixir
%{
  "require_verified_recipient" => true
}
```

Dispatch checks `enrollment.data["recipient_verified_at"]` and skips the send
when it is missing.

## Daily Caps

Daily caps defer sends after a sender mailbox reaches its configured limit:

```elixir
%{
  "sending_rules" => %{
    "daily_cap" => 50,
    "timezone" => "America/New_York"
  }
}
```

Caps may be set on the step or adapter, either under `"sending_rules"` or as a
flat `"daily_cap"` value. Step config wins when both are present. Invalid caps
fall back to 50 and valid caps are capped at 500.
