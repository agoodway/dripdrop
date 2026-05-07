# Short Links

Short links are resolved during dispatch after template rendering and before
adapter delivery.

## Pipeline

The pipeline:

* extracts URLs from `html`, `text`, and `body` payload fields;
* filters non-HTTP URLs, excluded patterns, and already-short domains;
* enriches eligible URLs with UTM data;
* resolves through the configured adapter;
* rewrites only URL-bearing attributes or plain-text URLs;
* persists provider-backed `short_links` rows keyed by idempotency data.

HTML rewriting uses Floki and only updates `href` and `src` attributes. Plain
text rewriting preserves trailing punctuation such as a final period.

## Adapters

Built-in adapters include:

* `DripDrop.ShortLinks.GoodAnalytics`
* `DripDrop.ShortLinks.Module`
* `DripDrop.ShortLinks.Webhook`
* `DripDrop.ShortLinks.None`

Configure `on_error: :send_originals` when delivery should continue if link
resolution fails. The original payload is delivered and the response metadata
records the short-link fallback.
