# Provider Integration Tests

Provider integration tests exercise outbound request shape and, where the
provider supports inbound delivery callbacks, webhook signature handling.

Use `DripDrop.DataCase` for provider tests that call channel modules and
`DripDrop.Web.WebhookPlug` directly. These tests do not need PgFlow. Full-stack
dispatch tests use `DripDrop.IntegrationCase` instead.

DripDrop's Docker test database listens on `localhost:54325`. This was checked
against sibling Docker setups under `/Users/chasepursley/Development/os/*` and
`/Users/chasepursley/Development/gw/*`: GoodSupport/GoodJobs use `54322`, and
PgFlow uses `54323`.

## Req.Test vs Bypass

- Mailgun, SendGrid, Slack, and Telegram use `Req` and honor
  `adapter.config["req_options"]` through `DripDrop.Channels.Helpers.request_options/1`.
- Twilio uses `Req` and honors the same `adapter.config["req_options"]` path.
- The task wording mentioned `adapter.config["channel_req_options"]`; the
  implemented per-adapter key is `req_options`. Global request options remain
  `config :dripdrop, :channel_req_options`.
- Because Twilio and Telegram both route through `Req`, provider tests can use
  `Req.Test`. Bypass is only needed for a future provider that bypasses `Req` or
  hides the client behind an SDK that cannot accept request options.

## Adding A Provider Test

Create `test/integration/providers/<provider>_test.exs`, add
`@moduletag :integration`, and cover:

- outbound URL/path, auth headers, and body shape
- normalized success result and provider message id
- inbound webhook acceptance for a valid signature when the provider supports it
- inbound rejection for a tampered signature
