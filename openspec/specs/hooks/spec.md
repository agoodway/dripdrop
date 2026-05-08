# hooks

## Purpose

Hooks define synchronous Elixir and HTTP extension points used by conditions, templates, and authoring-time tests.

## Requirements

### Requirement: Elixir Module Hooks Conform To A Behavior With Bounded Side Effects

The system SHALL define `DripDrop.HookBehavior` with a callback `handle_hook(name :: atom(), enrollment :: %DripDrop.Enrollment{}, context :: map()) :: {:ok, term()} | {:error, term()}`. Modules implementing the behavior SHALL be declared on the sequence via `sequences.hook_module`. The dispatcher SHALL invoke hooks ONLY inside the dispatch worker, never inside the request path that called `enroll/1`.

#### Scenario: Hook returns a value
- **WHEN** a hook function `:trial_days_remaining` returns `{:ok, 5}` during dispatch
- **THEN** the value is cached for the lifetime of this `step_execution_id` and is available both for condition evaluation and template variable resolution under the same key.

#### Scenario: Hook raises
- **WHEN** a hook function raises
- **THEN** dispatch catches the exception, emits a `[:dripdrop, :hook, :exception]` telemetry event with the stacktrace, treats the result as `{:error, :hook_exception}`, and applies the per-condition fail-closed semantics defined in `sequence-authoring`.

### Requirement: HTTP Hooks Are Stored With Encrypted Auth Configuration

The system SHALL persist `dripdrop.http_hooks` rows scoped to a `sequence_id` with unique `(sequence_id, key)`. Fields SHALL include `method`, `url` (Liquid-templated), `timeout_ms` (default 5000, max 30000), `retry_count` (default 2, max 5), `auth_type` (`none | bearer | basic | header`), `auth_config` (encrypted via `Cloak.Ecto.Map`), `headers` JSONB, `body_template` text, `response_path` (a JSONPath-like string), `response_type` (`json | text | number | boolean`), `active` flag, and test-result columns.

#### Scenario: Auth credentials encrypted
- **WHEN** an HTTP hook is created with `auth_type: "bearer", auth_config: %{token: "secret"}`
- **THEN** raw SQL inspection shows ciphertext in `auth_config` and the token never appears in `last_test_result`, telemetry, or audit snapshots.

#### Scenario: Reject excessive timeout
- **WHEN** a caller sets `timeout_ms: 60_000`
- **THEN** the changeset returns an error capping at 30000 ms.

### Requirement: HTTP Hook Evaluation Has Hard Timeouts And Bounded Retries

The system SHALL execute HTTP hooks via `Req` with `:receive_timeout`, `:pool_timeout`, and request `Idempotency-Key` headers (when `method != "GET"`). Failed hooks SHALL retry up to `retry_count` with exponential backoff capped at 30 seconds total. The hook evaluator SHALL never run unbounded — its outer timeout is enforced by a `Task.yield/2 + Task.shutdown/1` guard.

#### Scenario: Hook timeout
- **WHEN** an HTTP hook's endpoint takes longer than `timeout_ms`
- **THEN** the request is aborted, `{:error, :timeout}` is returned, retries fire up to `retry_count`, and final result is `{:error, :timeout}` if all retries exceed.

#### Scenario: Caching across uses within one execution
- **WHEN** the same `http_hook_id` is referenced by both a condition and a template variable in the same `step_execution_id`
- **THEN** the hook is invoked AT MOST ONCE; the result is cached for the duration of that execution.

### Requirement: HTTP Hook Bodies And URLs Use The Sequence's Template Engine

The system SHALL render `url` and `body_template` through the same template engine the `templates` capability uses for user-authored content, with the same variable scope (enrollment data + previously-resolved hook results). EEx SHALL NOT be used for HTTP hooks.

#### Scenario: URL templating
- **WHEN** a hook has `url: "https://api.example.com/users/{{subscriber_id}}/score"` and `subscriber_id: "u_123"`
- **THEN** the rendered URL is `https://api.example.com/users/u_123/score`.

#### Scenario: Body templating
- **WHEN** a hook has `body_template: ~s({"email": "{{email}}"})` and the enrollment has `data.email = "ada@example.com"`
- **THEN** the rendered body is `{"email": "ada@example.com"}`.

### Requirement: HTTP Hook URLs Are Validated Against Private Networks

To mitigate SSRF, the system SHALL reject HTTP hook URLs whose scheme is not `https` (with an opt-in `:http_hook_allow_http` config flag for development) and whose resolved IP addresses fall in any reserved range: RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`, `fe80::/10`), CGNAT (`100.64.0.0/10`), unspecified, multicast, future-use, RFC 5737 documentation ranges, and IPv6 unique-local (`fc00::/7`). Validation SHALL run twice: at `HttpHook` create/update time on the URL shape, and again at evaluator time on the rendered URL after Liquid expansion. The evaluator SHALL also disable HTTP redirects so the resolved host cannot be swapped at fetch time. Blocked URLs SHALL emit a `[:dripdrop, :hook, :url_blocked]` telemetry event with `http_hook_id`, `tenant_key`, the rejected URL, and the reason.

#### Scenario: Reject AWS metadata endpoint
- **WHEN** an `HttpHook` is created with `url: "https://169.254.169.254/latest/meta-data/"`
- **THEN** the changeset accepts the literal URL only if it is a Liquid template; the evaluator rejects the rendered URL with `{:error, {:url_blocked, :private_address}}` and emits the telemetry event.

#### Scenario: Liquid template that resolves to a private host
- **WHEN** a hook has `url: "https://{{host}}/score"` and the enrollment data renders the URL to `https://10.0.0.1/score`
- **THEN** the evaluator's post-render validation rejects the request before any network call and emits `[:dripdrop, :hook, :url_blocked]` with `reason: :private_address`.

#### Scenario: Reject non-HTTPS schemes
- **WHEN** an `HttpHook` is created with `url: "ftp://example.com/path"`
- **THEN** the changeset returns `{:error, ...}` with `scheme must be https`.

### Requirement: Response Extraction Coerces To Declared Type

When `response_type` is `number | boolean`, the system SHALL coerce the JSONPath-extracted value to that type and return `{:error, :coercion}` if coercion fails. When `response_type` is `text`, the value SHALL be returned as a string. When `response_type` is `json`, the entire decoded JSON SHALL be returned as a map/list.

#### Scenario: Numeric coercion
- **WHEN** a hook returns `{"score": "85"}`, `response_path: "score"`, `response_type: "number"`
- **THEN** the resolved value is `85` (integer).

#### Scenario: Coercion failure
- **WHEN** a hook returns `{"score": "high"}`, `response_path: "score"`, `response_type: "number"`
- **THEN** the resolved result is `{:error, :coercion}` and downstream conditions/templates treat it as a missing value.

### Requirement: Test Hook Endpoint Is Available Out Of Band

The system SHALL expose `DripDrop.test_http_hook(hook_id, test_data)` that runs a single hook invocation outside any enrollment, persists the result to `last_test_at` / `last_test_result`, and returns the same `{:ok, value} | {:error, reason}` shape as the in-dispatch path.

#### Scenario: Successful test stores result
- **WHEN** an operator calls `test_http_hook(hook_id, %{subscriber_id: "u_1", email: "x@y.com"})`
- **THEN** the hook fires, `last_test_at` is updated, `last_test_result` stores the response (with secrets redacted), and the function returns `{:ok, value}`.
