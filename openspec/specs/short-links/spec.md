# short-links

## Purpose

Short links define URL eligibility, enrichment, provider integration, idempotent persistence, and rewrite behavior before delivery.

## Requirements

### Requirement: Short-Link Adapter Behavior Defines A Uniform Provider Contract

The system SHALL define `DripDrop.ShortLinks.Adapter` with `create_link(request :: %DripDrop.ShortLinks.Request{}, opts :: keyword()) :: {:ok, %DripDrop.ShortLinks.Result{}} | {:error, %{kind: :temporary | :permanent, reason: term()}}`. The library SHALL ship four built-in adapters: `GoodAnalytics`, `Module`, `Webhook`, and `None`. Hosts wanting to integrate with hosted shortener APIs (e.g., Dub, Bitly, Rebrandly) configure `Webhook` against the provider's HTTP endpoint or write a small `Module` adapter — there is no built-in for any specific hosted shortener.

#### Scenario: None adapter is a no-op
- **WHEN** the configured adapter is `None` and short-linking is invoked
- **THEN** the original URL is returned unchanged (UTM enrichment may still apply if configured separately) and no `short_links` row is written.

### Requirement: Short-Link Generation Is Idempotent

The system SHALL compute a stable `idempotency_key` from the tuple `(step_execution_id, original_url, destination_url, provider, hash(provider_config))`. The library SHALL look up `dripdrop.short_links` by `idempotency_key` BEFORE calling the provider; if a row exists, the existing `short_url` SHALL be reused. The unique constraint on `idempotency_key` SHALL prevent races.

#### Scenario: Retry reuses existing short link
- **WHEN** dispatch retries a `step_execution_id` that previously produced `short_url: "https://go.example.com/abc"`
- **THEN** the second pass finds the existing `short_links` row, skips the provider call, and rewrites URLs identically to the first attempt.

#### Scenario: Different destinations get different short links
- **WHEN** the same execution renders two distinct destination URLs
- **THEN** two separate `short_links` rows are created (different `idempotency_key`s).

### Requirement: URL Eligibility Rules Skip Sensitive And Already-Short Links

The shortening pipeline SHALL skip URLs that are: non-http/https, already on a configured short-link domain, `mailto:`/`tel:`, or in a documented exclusion list (unsubscribe, privacy policy, password reset, signed/single-use tokens). Operators SHALL be able to add patterns via `config :dripdrop, short_links: [exclude_patterns: [~r/...]]` and via per-step `config["short_links"]["exclude"]`.

#### Scenario: Unsubscribe link is skipped
- **WHEN** an HTML body contains `<a href="https://example.com/unsubscribe?token=...">unsubscribe</a>`
- **THEN** the URL is left untouched even when shortening is enabled.

#### Scenario: Already-short URL skipped
- **WHEN** the configured short domain is `go.example.com` and the body contains `https://go.example.com/abc`
- **THEN** that URL is skipped (no double-shortening).

### Requirement: Rewriting Preserves HTML Structure And Plain-Text Punctuation

For HTML payloads, the system SHALL parse with an HTML parser (`Floki` or equivalent) and rewrite only `href`/`src` attributes (and their resolved query params for UTM enrichment). For plain-text payloads, the system SHALL tokenize URLs without including trailing punctuation (`.`, `,`, `)`, `]`, `;`, `:`, `!`, `?`).

#### Scenario: HTML rewrite leaves rest of document untouched
- **WHEN** the HTML is `<p>See <a href="https://example.com/x">here</a>.</p>`
- **THEN** only the `href` is rewritten; the surrounding `<p>` and trailing `.` stay byte-identical.

#### Scenario: Plain text trailing punctuation preserved
- **WHEN** the body is `Visit https://example.com/x.`
- **THEN** the rewrite produces `Visit <short>.` (the period is NOT swallowed into the URL).

### Requirement: Configuration Cascades Step → Sequence → Tenant → Global

The system SHALL resolve effective short-link configuration by merging in this order (later wins): global config from `config :dripdrop, short_links: [...]`, tenant config (when `tenant_key` matches), `sequence.metadata["short_links"]`, `step.config["short_links"]`. The merged config SHALL include `enabled`, `provider`, `domain`, `track_conversion`, `tag_names`, `external_id_strategy`, `utm_source/medium/campaign/content`, `exclude_patterns`, `on_error` (`:fail | :send_originals`).

#### Scenario: Step-level override
- **WHEN** the global config sets `provider: "webhook"` but a step sets `config["short_links"]["provider"]: "good_analytics"`
- **THEN** that step uses the GoodAnalytics provider while the rest of the sequence uses the webhook provider.

### Requirement: GoodAnalytics Provider Maps Onto Its Library API When In-Process

When the host application has the `GoodAnalytics` library available in the same OTP application, the `DripDrop.ShortLinks.GoodAnalytics` adapter SHALL call `GoodAnalytics.create_link/1` with `workspace_id`, `domain`, `key` (deterministic from idempotency_key by default), `url`, `link_type: "campaign"`, `utm_source: "dripdrop"`, `utm_medium: <channel>`, `utm_campaign: <sequence_key>`, `utm_content: <step_key>`, `external_id: <idempotency_key>`, and `metadata`. When `GoodAnalytics` is not available in-process, integration SHALL go through `DripDrop.ShortLinks.Webhook` instead.

#### Scenario: In-process GoodAnalytics call
- **WHEN** the host has `:good_analytics` in deps and `adapter: DripDrop.ShortLinks.GoodAnalytics`
- **THEN** the adapter invokes `GoodAnalytics.create_link/1` with the documented argument map and returns the result.

#### Scenario: Cross-app GoodAnalytics via webhook
- **WHEN** the host does not have `:good_analytics` loaded but configures `adapter: DripDrop.ShortLinks.Webhook` pointed at the GoodAnalytics Pro API
- **THEN** the adapter posts the normalized request to that endpoint and parses the response into a `Result`.

### Requirement: Failure Mode Is Configurable Per Step

The system SHALL honor `short_links.on_error` with values `:fail` (default) and `:send_originals`. On `:fail`, a permanent provider error SHALL fail the step execution. On `:send_originals`, the dispatch SHALL log the error, leave URLs unchanged, and proceed to deliver — recording the fallback in `step_executions.response.short_links_fallback`.

#### Scenario: Fallback to original URLs
- **WHEN** the provider returns `{:error, %{kind: :permanent, reason: :api_down}}` and the step has `on_error: :send_originals`
- **THEN** dispatch sends the message with original URLs, the execution succeeds, and the fallback flag is recorded for audit.
