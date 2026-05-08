# Cold Outbound

Cold outbound mode is for prospect drip campaigns where sender continuity,
mailbox reputation, and reply threading matter. Lifecycle sequences remain the
default and should be used for onboarding, product nudges, win-backs, and other
known-user messaging where per-step adapter rotation is acceptable.

Outbound mode is opt-in per sequence version:

```elixir
{:ok, pool} =
  DripDrop.create_adapter_pool(%{
    tenant_key: "acct_123",
    name: "sales_pool",
    on_pin_unavailable: :pause
  })

{:ok, _member} =
  DripDrop.add_pool_member(pool.id, %{
    adapter_id: gmail_adapter.id,
    class: :mailbox,
    weight: 1
  })

{:ok, version} =
  DripDrop.create_sequence_version(sequence.id, %{
    version: 2,
    mode: :outbound,
    config: %{"pool_id" => pool.id}
  })
```

When a subscriber enrolls, DripDrop chooses one active pool member with WDRR and
stores it on `enrollments.adapter_id`. Every step for that enrollment uses the
same adapter unless a step has `adapter_override_id`, which intentionally starts
a new thread.

## Pool Authoring

Use one tenant-scoped pool per sender group. Keep mailbox pools and ESP API
pools separate unless the host has a clear reason to mix classes. Mailbox class
members are intended for Gmail, Microsoft 365, SMTP mailboxes, and equivalent
per-inbox senders. ESP API members are intended for providers such as Mailgun,
SendGrid, Postmark, MailerSend, and SES.

Pool policies:

- `on_pin_unavailable: :pause` stops new enrollment when no eligible sender is
  available and pauses in-flight enrollments whose pinned sender becomes
  terminally unavailable.
- `on_pin_unavailable: :reassign` lets operators continue through a different
  active member, with a sender-reassigned event and thread break.

Existing pins are not automatically rebalanced when pool membership changes.
Use `DripDrop.repin_enrollment/3` for explicit operator moves.

## Ramp Planning

Set ramp fields on each outbound adapter:

```elixir
DripDrop.update_channel_adapter(adapter, %{
  health_state: :ramping,
  daily_cap: 40,
  ramp_floor: 5,
  ramp_increment: 3,
  ramp_started_at: DateTime.utc_now(),
  min_gap_seconds: 90
})
```

Effective daily cap is:

```text
min(daily_cap, ramp_floor + days_elapsed * ramp_increment)
```

Example 14-day ramp for a new Gmail or Microsoft 365 mailbox:

| Day | Cap |
|-----|-----|
| 1   | 5   |
| 2   | 8   |
| 3   | 11  |
| 4   | 14  |
| 5   | 17  |
| 6   | 20  |
| 7   | 23  |
| 8   | 26  |
| 9   | 29  |
| 10  | 32  |
| 11  | 35  |
| 12  | 38  |
| 13  | 40  |
| 14  | 40  |

Use lower floors, slower increments, and longer min-gap values for brand-new
domains or mailboxes with weak reputation. Hosts can feed external signals with
`DripDrop.set_adapter_health/2`; DripDrop then routes new pins around resting
mailboxes and probes recovery before ramping again.

## Threading Verification

Outbound email steps generate and persist a DripDrop RFC `Message-ID` in
`step_executions.out_message_id`. Follow-up steps stamp:

- `Message-ID` for the new send.
- `In-Reply-To` pointing at the previous non-override send.
- `References` containing the thread chain.

Verify threading by querying:

```sql
SELECT step_id, out_message_id, payload->'headers'
FROM dripdrop.step_executions
WHERE enrollment_id = $1
ORDER BY inserted_at;
```

Provider ids stay in `provider_message_id`; do not use them as RFC threading
ids.

## Inbound Pumping

DripDrop does not own inbound polling. The host receives mailbox changes,
normalizes the message, and calls `DripDrop.ingest_inbound_message/2`.

### IMAP

```elixir
def handle_imap_message(adapter, message) do
  DripDrop.ingest_inbound_message(adapter.id, %{
    message_id: header(message, "Message-ID"),
    in_reply_to: header(message, "In-Reply-To"),
    references: split_references(header(message, "References")),
    from: header(message, "From"),
    to: header(message, "To"),
    subject: header(message, "Subject"),
    body_text: text_part(message),
    body_html: html_part(message),
    headers: raw_headers(message),
    received_at: received_at(message),
    intent: classify(message)
  })
end
```

### Microsoft Graph

Microsoft Graph change notifications can subscribe to
`me/mailFolders('Inbox')/messages` or `/me/mailfolders('inbox')/messages`.
Notifications provide the message resource/id; fetch the message and select
`internetMessageHeaders` to extract `Message-ID`, `In-Reply-To`, and
`References`.

```elixir
def handle_graph_notification(adapter, graph_client, message_id) do
  message =
    graph_client.get!(
      "/me/messages/#{message_id}",
      query: %{"$select" => "from,toRecipients,subject,body,internetMessageHeaders,receivedDateTime"}
    )

  headers = Map.new(message.internetMessageHeaders, &{String.downcase(&1.name), &1.value})

  DripDrop.ingest_inbound_message(adapter.id, %{
    message_id: headers["message-id"],
    in_reply_to: headers["in-reply-to"],
    references: split_references(headers["references"]),
    from: message.from.emailAddress.address,
    to: first_recipient(message),
    subject: message.subject,
    body_html: message.body.content,
    headers: headers,
    received_at: parse_graph_time(message.receivedDateTime),
    intent: :reply
  })
end
```

### Gmail API Watch

Gmail `users.watch` sends Cloud Pub/Sub notifications that contain the mailbox
email address and latest `historyId`, not the full message. Use
`users.history.list` from the previous stored history id, then call
`users.messages.get` for new message ids with metadata or full/raw format and
extract `Message-ID`, `In-Reply-To`, and `References`.

```elixir
def handle_gmail_notification(adapter, gmail, notification, last_history_id) do
  history =
    gmail.history_list("me", startHistoryId: last_history_id)

  for message_id <- new_message_ids(history) do
    message = gmail.messages_get("me", message_id, format: "metadata")
    headers = gmail_headers(message.payload.headers)

    DripDrop.ingest_inbound_message(adapter.id, %{
      message_id: headers["message-id"],
      in_reply_to: headers["in-reply-to"],
      references: split_references(headers["references"]),
      from: headers["from"],
      to: headers["to"],
      subject: headers["subject"],
      headers: headers,
      received_at: DateTime.utc_now(),
      intent: :reply
    })
  end
end
```

Persist the newest Gmail `historyId` after successful processing so the next
notification can be reconciled without missing messages.

## Operator Runbook

Pool exhausted:

1. Inspect `[:dripdrop, :dispatch, :pool_exhausted]` metadata for `pool_id`,
   `tenant_key`, and evicted adapter ids.
2. Check `channel_adapters.health_state`, `resting_until`, `daily_cap`, and
   recent `message_events`.
3. Add capacity, lower sequence volume, or manually repin stalled enrollments.

Adapter resting:

1. Confirm whether the state came from bounce/complaint thresholds or
   `set_adapter_health/2`.
2. Leave the adapter resting through its cooldown unless an operator has
   independent evidence that the signal was bad.
3. After `resting_until`, probing permits a small fixed send budget. Clean probe
   sends move the adapter to ramping; new breaches double the cooldown up to the
   configured cap.

Threading drift:

1. Confirm the outbound row has `out_message_id`.
2. Confirm the provider payload contained `Message-ID`, `In-Reply-To`, and
   `References`.
3. Confirm the inbound pump preserves reply headers and calls
   `DripDrop.ingest_inbound_message/2` with ids normalized without angle
   brackets.
