# Lifecycle Email

Lifecycle sequence email can use HTML, MJML, Liquid templates, and
provider-specific adapters.

## Payload Shape

Email templates render to a payload with the normal email fields:

```elixir
%{
  to: "customer@example.com",
  from: "hello@example.com",
  subject: "Welcome",
  text: "Thanks for joining.",
  html: "<p>Thanks for joining.</p>"
}
```

Email steps can opt into unsubscribe headers with `"unsubscribe_headers"`,
`"unsubscribe"`, or nested `"email" => %{"unsubscribe_headers" => true}`.
Configure `:unsubscribe_url_builder` so the host can return the unsubscribe
URL inserted into RFC 8058 headers.

## Providers

Swoosh-backed providers use Swoosh adapters where they exist. Gmail and MS365
use direct APIs with a host-owned `token_callback`; DripDrop never stores
refresh tokens or OAuth client secrets.

## Provider Webhooks

Mailgun, SendGrid, Postmark, MailerSend, and SES webhook events are normalized
into `message_events`. Complaints, unsubscribes, and bounces normalized with
`severity: "permanent"` upsert suppressions in the same transaction.
