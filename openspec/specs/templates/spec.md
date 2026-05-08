# templates

## Purpose

Templates define rendering engines, variable scope, authoring validation, MJML support, and per-channel payload shapes.

## Requirements

### Requirement: Default Template Engine For User-Authored Content Is Liquid (Liquex)

The system SHALL render user-authored templates (step subjects, bodies, SMS content, webhook bodies, Slack/Telegram text, HTTP hook URLs and bodies) through `Liquex` by default. EEx SHALL be reserved for templates whose source is a trusted Elixir module (`template_type: "module"`). Liquid templates SHALL render missing variables as empty strings while collecting missing-variable warnings so a misnamed variable does NOT crash dispatch.

#### Scenario: Liquid render with enrollment variables
- **WHEN** a step has `body: "Hi {{name}}!"` and the enrollment has `data: %{"name" => "Ada"}`
- **THEN** the rendered output is `"Hi Ada!"`.

#### Scenario: Missing variable renders as empty
- **WHEN** a template references `{{ totally_missing }}` and no value resolves
- **THEN** the rendered output substitutes an empty string and emits a `[:dripdrop, :template, :missing_variable]` telemetry event with the variable name (so operators can find typos without breaking sends).

#### Scenario: EEx is rejected for inline templates
- **WHEN** a step is created with `template_type: "inline"` and the body contains `<%= name %>`
- **THEN** the render output is the literal string `<%= name %>` because Liquid does not evaluate EEx tags.

### Requirement: Module Templates Are Compiled Elixir Functions With An Explicit Contract

When `template_type == "module"`, the step SHALL specify `template_module` and `template_function`. The function SHALL accept `(enrollment, hook_results, channel_config) :: {:ok, rendered :: map()} | {:error, term()}`. Module templates MAY use EEx, sigils, or any Elixir construct. They run inside the dispatch worker only.

#### Scenario: Module template returns rendered payload
- **WHEN** a step has `template_module: "MyApp.Templates.Welcome", template_function: "render"` and that function returns `{:ok, %{subject: "Welcome", html: "<p>Hi</p>", text: "Hi"}}`
- **THEN** dispatch uses those keys verbatim for the channel adapter's payload.

### Requirement: MJML Email Templates Compile To Responsive HTML

When a step's `config.body_format == "mjml"` (or the inline body starts with `<mjml>`), the system SHALL run the rendered Liquid output through `Mjml.to_html/1` and use the resulting HTML as the `html_body`. Compilation errors SHALL be returned as `{:error, %{kind: :permanent, reason: {:mjml_compile, errors}}}` from the templates capability so dispatch fails fast without retrying.

#### Scenario: MJML compiles and is sent
- **WHEN** a step's body is `<mjml><mj-body>Hi {{name}}</mj-body></mjml>` and `name = "Ada"`
- **THEN** the engine first renders Liquid to `<mjml><mj-body>Hi Ada</mj-body></mjml>` then compiles MJML to responsive HTML.

#### Scenario: MJML compile error
- **WHEN** the rendered Liquid output is malformed MJML
- **THEN** the templates capability returns `{:error, %{kind: :permanent, reason: {:mjml_compile, _}}}` and dispatch fails the execution without retrying (a permanent compile error will not self-heal).

### Requirement: Variable Scope Combines Enrollment, Subscriber, Hooks, And Step Config

The variable resolver SHALL expose, in order of override (highest wins): step `config["template_variables"]`, hook results captured during the same execution, `enrollment.data` keys, and a small set of system variables (`subscriber_id`, `subscriber_type`, `enrollment_id`, `step_key`, `sequence_key`, `tenant_key`, `now_iso8601`).

#### Scenario: Hook value overrides enrollment data
- **WHEN** an enrollment has `data: %{"score" => 50}` and a hook resolves `:score = 80` for the same execution
- **THEN** `{{ score }}` renders as `80`.

#### Scenario: System variable available
- **WHEN** a template references `{{ now_iso8601 }}` during dispatch at `2026-05-06T12:00:00Z`
- **THEN** the rendered value is `2026-05-06T12:00:00Z`.

### Requirement: Templates Are Validated At Authoring Time

The `templates` capability SHALL expose `DripDrop.Templates.validate/2` that parses Liquid (or MJML) source and returns either `:ok` or `{:error, [{line, column, message}]}`. The `sequence-authoring` validator SHALL call this for every step before activation.

#### Scenario: Liquid syntax error rejected
- **WHEN** a body contains `Hi {{name` (unclosed tag)
- **THEN** validation returns `{:error, [{1, _, "unclosed expression"}]}` and authoring's `validate_sequence_version/1` includes the error.

### Requirement: Render Output Per Channel Has A Documented Shape

The system SHALL produce per-channel rendered payloads with these shapes:

- `email`: `%{subject: binary, text: binary | nil, html: binary | nil, headers: map}` — at least one of `:text` or `:html` SHALL be present.
- `sms`: `%{body: binary, media_urls: [binary]}` — `body` length SHALL NOT exceed configured `step.config["sms_max_chars"]` (default 1600).
- `webhook`: `%{url: binary, method: atom, headers: map, body: binary | map}`.
- `pubsub`: `%{topic: binary, event: binary, payload: term}`.
- `slack`: `%{channel: binary | nil, text: binary, blocks: list | nil}`.
- `telegram`: `%{chat_id: integer | binary, text: binary, parse_mode: "Markdown" | "HTML" | nil}`.

#### Scenario: Email payload validation
- **WHEN** rendering an email step
- **THEN** the templates capability returns a map with `:subject` non-empty and at least one of `:text` or `:html`; otherwise it returns `{:error, %{kind: :permanent, reason: :empty_body}}`.

#### Scenario: SMS body length cap
- **WHEN** a rendered SMS body is 2000 characters and `sms_max_chars` is 1600
- **THEN** the templates capability returns `{:error, %{kind: :permanent, reason: :sms_too_long}}` rather than silently truncating.
