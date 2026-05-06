# DripDrop: Universal Multi-Channel Messaging Sequences for Elixir

## Overview

DripDrop is a database-driven, multi-channel messaging sequence engine for Elixir. Orchestrates behavioral message sequences across email, SMS, webhooks, in-app notifications, and messaging platforms with intelligent timing, branching logic, and dynamic data integration.

**Core Principles:**
- Backend-first: Works standalone without UI
- Pluggable: Add to existing apps
- Multi-channel: Email, SMS, webhooks, PubSub, Slack, Telegram, etc.
- Behavioral: Adapts based on user actions
- Extensible: Hook into any data source
- Optional UI: LiveView dashboard via router mount

## Tech Stack

**Required:**
- PostgreSQL 17+ with schemas support
- [ecto_evolver](https://github.com/agoodway/ecto_evolver) - Versioned SQL migrations for Elixir libraries
- [pgflow](https://github.com/agoodway/pgflow) - Default workflow/job execution engine
- [crontab](https://hex.pm/packages/crontab) - Cron parsing/validation
- Ecto - Database layer

**Optional:**
- Phoenix LiveView - Dashboard UI
- Req - HTTP client for webhooks/hooks
- Swoosh - Email delivery
- Solid - Liquid templates
- MJML - Responsive email templates
- ReqLLM + Zoi - AI template generation

## Architecture

DripDrop stores sequence configuration, enrollment state, delivery policy, and provider event history in the `dripdrop` schema. PgFlow stores workflow/job runtime state in its own `pgflow` schema. The two schemas are intentionally separate: DripDrop owns messaging domain data; PgFlow owns queueing, worker coordination, retries, and run history.

DripDrop uses a durable dispatch boundary. Public APIs write sequence/enrollment/execution records through Ecto transactions, then enqueue PgFlow work using stable database IDs. Dispatch workers claim due executions from the database, evaluate policy and conditions, send through the selected adapter, persist provider results, and schedule the next transition.

Step execution is idempotent. Each execution has a stable idempotency key and can be retried after worker crashes or transient provider failures without intentionally sending duplicate messages. Provider-specific idempotency is used where available.

Sequences support both linear ordering and explicit transitions. `position` is useful for authoring and display; branching uses `step_transitions` plus conditions so a sequence can express entry points, exits, fallback paths, and multiple conditional next steps.

Messaging policy is part of the core domain. Suppression, consent, unsubscribe, bounce, complaint, reply, rate-limit, quiet-hour, and provider event handling are checked before or during dispatch, not bolted onto individual adapters.

Cold outbound and lifecycle/transactional messaging are treated as different operating modes. Cold outbound defaults to plain text, separate sending domains/mailboxes, verified addresses, and conservative per-inbox volume. Lifecycle and transactional email can use HTML/MJML but still requires sender authentication, applicable unsubscribe headers, and bounce/complaint handling.

## Database Architecture

### Schema: `dripdrop` (ecto_evolver managed)

```sql
CREATE SCHEMA dripdrop;
```

DripDrop uses `ecto_evolver` with raw SQL migrations:

```elixir
defmodule DripDrop.Migration do
  use EctoEvolver,
    otp_app: :dripdrop,
    default_prefix: "dripdrop",
    versions: [DripDrop.Migrations.V01],
    tracking_object: {:view, "dripdrop_version"}
end
```

**Core Tables:**

```elixir
# dripdrop.sequences
- id (uuid, pk)
- tenant_key (string, nullable) - optional host-app tenant/account boundary
- name (string)
- key (string, unique)
- description (text)
- hook_module (string) - Elixir module for hooks
- active (boolean)
- metadata (jsonb)
- inserted_at, updated_at

# dripdrop.sequence_versions
- id (uuid, pk)
- sequence_id (uuid, fk)
- version (integer)
- name (string)
- state (string) - "draft", "active", "archived"
- config (jsonb)
- published_at (utc_datetime)
- inserted_at, updated_at
- unique constraint: [sequence_id, version]

# dripdrop.steps
- id (uuid, pk)
- sequence_version_id (uuid, fk)
- name (string)
- key (string) - unique within version
- position (integer)
- channel (string) - "email", "sms", "webhook", "pubsub", "slack", "telegram"
- timing (jsonb) - embedded timing configuration
- template_type (string) - "inline", "module", "external"
- template_content (jsonb)
- template_module (string)
- template_function (string)
- channel_adapter_id (uuid, fk nullable) - specific adapter to use
- config (jsonb)
- active (boolean)
- inserted_at, updated_at
- unique constraint: [sequence_version_id, key]

# dripdrop.step_transitions
- id (uuid, pk)
- sequence_version_id (uuid, fk)
- from_step_id (uuid, fk nullable) - null means sequence entry
- to_step_id (uuid, fk nullable) - null means complete enrollment
- condition_mode (string) - "always", "all", "any"
- priority (integer)
- config (jsonb)
- inserted_at, updated_at

# dripdrop.channel_adapters
- id (uuid, pk)
- name (string)
- channel (string) - "email", "sms", etc.
- provider (string) - "mailgun", "sendgrid", "twilio", etc.
- credentials (binary) - encrypted with Cloak/Ecto encrypted type
- config (jsonb)
- is_default (boolean)
- active (boolean)
- inserted_at, updated_at

# dripdrop.conditions
- id (uuid, pk)
- step_id (uuid, fk nullable)
- transition_id (uuid, fk nullable)
- condition_type (string) - "hook", "enrollment_data", "event", "time_window"
- operator (string) - "eq", "neq", "gt", "lt", "gte", "lte", "in", "contains"
- hook_function (string) - for Elixir module hooks
- http_hook_id (uuid, fk nullable)
- field_path (string) - JSONPath for enrollment_data
- expected_value (string)
- config (jsonb)
- inserted_at, updated_at

# dripdrop.http_hooks
- id (uuid, pk)
- sequence_id (uuid, fk)
- name (string)
- key (string) - unique within sequence
- description (text)
- method (string) - "GET", "POST", etc.
- url (string)
- timeout_ms (integer, default: 5000)
- retry_count (integer, default: 2)
- auth_type (string) - "none", "bearer", "basic", "header"
- auth_config (binary) - encrypted
- headers (jsonb)
- body_template (text)
- response_path (string) - JSONPath
- response_type (string) - "json", "text", "number", "boolean"
- active (boolean)
- last_test_at (utc_datetime)
- last_test_result (jsonb)
- inserted_at, updated_at
- unique constraint: [sequence_id, key]

# dripdrop.enrollments
- id (uuid, pk)
- sequence_id (uuid, fk)
- sequence_version_id (uuid, fk)
- subscriber_type (string) - polymorphic: "User", "Lead", etc.
- subscriber_id (string) - host-app identifier; do not require UUID
- state (string) - "active", "paused", "completed", "cancelled"
- current_step_id (uuid, fk nullable)
- started_at (utc_datetime)
- completed_at (utc_datetime)
- cancelled_at (utc_datetime)
- data (jsonb) - enrollment-specific data
- metadata (jsonb)
- inserted_at, updated_at
- unique constraint: [sequence_id, subscriber_type, subscriber_id]

# dripdrop.step_executions
- id (uuid, pk)
- enrollment_id (uuid, fk)
- step_id (uuid, fk)
- state (string) - "scheduled", "claiming", "sending", "sent", "failed", "skipped", "cancelled"
- scheduled_for (utc_datetime)
- claimed_at (utc_datetime)
- executed_at (utc_datetime)
- failed_at (utc_datetime)
- retry_count (integer, default: 0)
- idempotency_key (string, unique)
- pgflow_run_id (string nullable)
- channel (string)
- recipient (string) - email, phone, url, etc.
- payload (jsonb)
- response (jsonb)
- provider_message_id (string)
- error_message (text)
- inserted_at, updated_at

# dripdrop.events
- id (uuid, pk)
- enrollment_id (uuid, fk nullable)
- subscriber_type (string, nullable)
- subscriber_id (string, nullable)
- event_type (string) - "user_action", "milestone", "custom"
- event_key (string)
- event_data (jsonb)
- occurred_at (utc_datetime)
- inserted_at, updated_at

# dripdrop.suppressions
- id (uuid, pk)
- channel (string)
- recipient (string)
- reason (string) - "unsubscribe", "bounce", "complaint", "manual", "provider_block"
- source (string)
- metadata (jsonb)
- inserted_at, updated_at
- unique constraint: [channel, recipient]

# dripdrop.message_events
- id (uuid, pk)
- step_execution_id (uuid, fk nullable)
- channel (string)
- provider (string)
- provider_message_id (string)
- event_type (string) - "delivered", "bounced", "complained", "opened", "clicked", "replied", "unsubscribed"
- event_data (jsonb)
- occurred_at (utc_datetime)
- inserted_at

# dripdrop.short_links
- id (uuid, pk)
- step_execution_id (uuid, fk nullable)
- provider (string) - "dub", "goodanalytics", "module", "webhook", "none"
- original_url (text)
- destination_url (text) - final URL sent to provider after UTM/enrichment
- short_url (text)
- external_id (string)
- idempotency_key (string, unique)
- metadata (jsonb)
- inserted_at, updated_at
```

Constraints and indexes:

- Unique sequence keys include tenant scope when `tenant_key` is used.
- Allow only one active sequence version per sequence with a partial unique index.
- Enforce unique step keys and positions per sequence version.
- Index due work by `(state, scheduled_for)` and enrollment state by `(sequence_id, state)`.
- Index event lookup by `(subscriber_type, subscriber_id, event_key, occurred_at)`.
- Use GIN indexes on JSONB only for documented query paths; avoid indexing every metadata field by default.
- Claim due executions with a compare-and-set update or row lock. Never rely on in-memory process state for execution ownership.

## Timing Configuration

Uses `crontab` for cron parsing/validation. Human-friendly expressions such as `"every monday at 9am"` require a DripDrop parser that converts to either cron or delay configuration before storage.

### Timing Struct (Embedded in Step)

```elixir
defmodule DripDrop.Timing do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :type, :string  # "immediate", "delay", "cron", "event"
    
    # For delay type
    field :delay_amount, :integer
    field :delay_unit, :string  # "minutes", "hours", "days", "weeks"
    
    # For cron type
    field :cron_expression, :string  # "0 9 * * MON" or "@daily"
    field :timezone, :string, default: "UTC"
    
    # For event type
    field :trigger_event, :string
    field :trigger_data, :map
    
    # Human-friendly alternatives
    field :human_expression, :string  # "every monday at 9am", "in 3 days"
  end

  @delay_units ~w(minutes hours days weeks)
  @timing_types ~w(immediate delay cron event)

  def changeset(timing, attrs) do
    timing
    |> cast(attrs, [
      :type, :delay_amount, :delay_unit, 
      :cron_expression, :timezone,
      :trigger_event, :trigger_data,
      :human_expression
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, @timing_types)
    |> validate_by_type()
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      "delay" ->
        changeset
        |> validate_required([:delay_amount, :delay_unit])
        |> validate_inclusion(:delay_unit, @delay_units)
        |> validate_number(:delay_amount, greater_than: 0)
      
      "cron" ->
        changeset
        |> validate_required([:cron_expression])
        |> validate_cron_expression()
      
      "event" ->
        validate_required(changeset, [:trigger_event])
      
      _ ->
        changeset
    end
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil -> changeset
      expr ->
        # Parse human-friendly or cron format
        case parse_timing_expression(expr) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :cron_expression, reason)
        end
    end
  end

  def parse_timing_expression(expr) do
    # Try human-friendly first
    case parse_human_friendly(expr) do
      {:ok, cron} -> {:ok, cron}
      {:error, _} ->
        # Try parsing as cron
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, cron_expr} -> {:ok, cron_expr}
          {:error, reason} -> {:error, "Invalid timing expression: #{reason}"}
        end
    end
  end

  defp parse_human_friendly(expr) do
    # Convert human expressions to cron
    case String.downcase(expr) do
      "@daily" -> Crontab.CronExpression.Parser.parse("0 0 * * *")
      "@hourly" -> Crontab.CronExpression.Parser.parse("0 * * * *")
      "@weekly" -> Crontab.CronExpression.Parser.parse("0 0 * * 0")
      "every day at " <> time -> parse_daily_at(time)
      "every monday at " <> time -> parse_weekday_at(time, "1")
      "in " <> duration -> parse_delay(duration)
      _ -> {:error, "Unrecognized format"}
    end
  end

  defp parse_daily_at(time) do
    # Parse "9am", "3:30pm", etc.
    # Returns cron expression
  end

  defp parse_delay(duration) do
    # Parse "3 days", "2 hours", etc.
    # Convert to delay configuration
  end

  def calculate_next_run(%__MODULE__{type: "immediate"}, _from) do
    DateTime.utc_now()
  end

  def calculate_next_run(%__MODULE__{type: "delay"} = timing, from) do
    seconds = convert_to_seconds(timing.delay_amount, timing.delay_unit)
    DateTime.add(from, seconds, :second)
  end

  def calculate_next_run(%__MODULE__{type: "cron"} = timing, from) do
    {:ok, cron} = Crontab.CronExpression.Parser.parse(timing.cron_expression)
    tz = timing.timezone || "UTC"
    
    from
    |> DateTime.shift_zone!(tz)
    |> Crontab.Scheduler.get_next_run_date(cron)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp convert_to_seconds(amount, "minutes"), do: amount * 60
  defp convert_to_seconds(amount, "hours"), do: amount * 3600
  defp convert_to_seconds(amount, "days"), do: amount * 86400
  defp convert_to_seconds(amount, "weeks"), do: amount * 604800
end
```

### Usage Examples

```elixir
# Immediate
%{timing: %{type: "immediate"}}

# Delay
%{timing: %{
  type: "delay",
  delay_amount: 3,
  delay_unit: "days"
}}

# Cron expression
%{timing: %{
  type: "cron",
  cron_expression: "0 9 * * MON",  # Every Monday at 9am
  timezone: "America/New_York"
}}

# Human-friendly
%{timing: %{
  type: "cron",
  cron_expression: "every monday at 9am",
  timezone: "America/New_York"
}}

# Event-triggered
%{timing: %{
  type: "event",
  trigger_event: "order_completed"
}}
```

## Channel Adapters (Database-Stored)

### Schema

```elixir
defmodule DripDrop.ChannelAdapter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dripdrop.channel_adapters" do
    field :name, :string
    field :channel, :string
    field :provider, :string
    field :credentials, DripDrop.Encrypted.Map  # Ecto encrypted type
    field :config, :map
    field :is_default, :boolean, default: false
    field :active, :boolean, default: true

    timestamps()
  end

  @channels ~w(email sms webhook pubsub slack telegram)
  
  def changeset(adapter, attrs) do
    adapter
    |> cast(attrs, [:name, :channel, :provider, :credentials, :config, :is_default, :active])
    |> validate_required([:name, :channel, :provider])
    |> validate_inclusion(:channel, @channels)
    |> validate_credentials()
  end

  defp validate_credentials(changeset) do
    provider = get_field(changeset, :provider)
    credentials = get_field(changeset, :credentials) || %{}
    
    case DripDrop.Channels.get_adapter_module(get_field(changeset, :channel), provider) do
      {:ok, module} ->
        case module.validate_credentials(credentials) do
          :ok -> changeset
          {:error, errors} ->
            Enum.reduce(errors, changeset, fn {field, msg}, acc ->
              add_error(acc, :credentials, "#{field}: #{msg}")
            end)
        end
      {:error, _} ->
        add_error(changeset, :provider, "Unknown provider")
    end
  end
end
```

### Encrypted Credentials

```elixir
# lib/dripdrop/encrypted/map.ex
defmodule DripDrop.Encrypted.Map do
  use Cloak.Ecto.Map, vault: DripDrop.Vault
end

# lib/dripdrop/vault.ex
defmodule DripDrop.Vault do
  use Cloak.Vault, otp_app: :dripdrop

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1",
          key: decode_env!("DRIPDROP_ENCRYPTION_KEY")
        }
      )

    {:ok, config}
  end

  defp decode_env!(var) do
    var
    |> System.get_env()
    |> Base.decode64!()
  end
end
```

### Usage

```elixir
# Create email adapter (Mailgun)
{:ok, mailgun} = DripDrop.create_channel_adapter(%{
  name: "Mailgun Primary",
  channel: "email",
  provider: "mailgun",
  credentials: %{
    api_key: System.get_env("MAILGUN_API_KEY"),
    domain: "mg.myapp.com"
  },
  is_default: true
})

# Create second email adapter (SendGrid)
{:ok, sendgrid} = DripDrop.create_channel_adapter(%{
  name: "SendGrid Transactional",
  channel: "email",
  provider: "sendgrid",
  credentials: %{
    api_key: System.get_env("SENDGRID_API_KEY")
  },
  is_default: false
})

# Use specific adapter in step
DripDrop.create_step(version.id, %{
  name: "Welcome Email",
  channel: "email",
  channel_adapter_id: sendgrid.id,  # Override default
  config: %{
    "subject" => "Welcome!",
    "body" => "..."
  }
})

# Use default adapter (no channel_adapter_id specified)
DripDrop.create_step(version.id, %{
  name: "Newsletter",
  channel: "email",
  # Uses Mailgun (is_default: true)
  config: %{...}
})

# Create SMS adapter (Twilio)
{:ok, _} = DripDrop.create_channel_adapter(%{
  name: "Twilio US",
  channel: "sms",
  provider: "twilio",
  credentials: %{
    account_sid: System.get_env("TWILIO_SID"),
    auth_token: System.get_env("TWILIO_TOKEN")
  },
  config: %{
    from: "+15551234567"
  },
  is_default: true
})

# Create Slack adapter
{:ok, _} = DripDrop.create_channel_adapter(%{
  name: "Company Slack",
  channel: "slack",
  provider: "webhook",
  credentials: %{
    webhook_url: System.get_env("SLACK_WEBHOOK_URL")
  },
  is_default: true
})

# Create Telegram adapter
{:ok, _} = DripDrop.create_channel_adapter(%{
  name: "Telegram Bot",
  channel: "telegram",
  provider: "bot_api",
  credentials: %{
    bot_token: System.get_env("TELEGRAM_BOT_TOKEN")
  },
  is_default: true
})
```

### Adapter Rotation Strategy

```elixir
# Rotate between multiple email adapters per sequence
sequence_config = %{
  channel_rotation: %{
    email: [
      %{adapter_id: mailgun_id, weight: 70},
      %{adapter_id: sendgrid_id, weight: 30}
    ]
  }
}

# Or per step
step_config = %{
  channel_adapter_rotation: [mailgun_id, sendgrid_id, postmark_id]
}
```

## Scheduler Integration

### Default: pgflow

DripDrop uses PgFlow for durable execution, not as tables embedded in the `dripdrop` schema. PgFlow installs and owns the `pgflow` schema; DripDrop installs and owns the `dripdrop` schema.

Required PgFlow setup in the host app:

```bash
mix pgflow.gen.postgres_extensions_migration
mix pgflow.gen.pgmq_migration
mix pgflow.setup
mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep
mix ecto.migrate
```

If the deployment cannot enable pg_cron, generate extensions with `--no-cron`. DripDrop can still run delay/event-driven executions through PgFlow workers, but cron-triggered steps require either pg_cron or an alternate scheduler.

```elixir
# config/config.exs
config :my_app, MyApp.PgFlow,
  repo: MyApp.Repo,
  jobs: [DripDrop.Jobs.DispatchStep],
  signal_strategy: :notify

config :dripdrop,
  repo: MyApp.Repo,
  scheduler: DripDrop.Schedulers.Pgflow
```

Dispatch model:

- `DripDrop.enroll/1` creates an enrollment and the first `step_execution` rows inside one `Ecto.Multi`.
- A PgFlow job receives only stable IDs, for example `%{"step_execution_id" => "..."}`.
- The worker claims the execution with a compare-and-set update, checks suppressions/conditions/quiet hours, renders payload, sends via the adapter, stores provider response, and advances the enrollment.
- Retries must be idempotent. Use `step_executions.idempotency_key` and provider-specific idempotency support where available.

### Alternative: Oban

```elixir
config :dripdrop,
  scheduler: DripDrop.Schedulers.Oban,
  oban: [
    repo: MyApp.Repo,
    queues: [dripdrop: 10]
  ]
```

### Custom Scheduler

```elixir
defmodule MyApp.CustomScheduler do
  @behaviour DripDrop.Scheduler

  @impl true
  def schedule(execution, scheduled_for) do
    # Your implementation
    {:ok, job_id}
  end

  @impl true
  def cancel(job_id) do
    :ok
  end
end
```

## Hook System

Hooks must never run unbounded in the caller's request path. Evaluate hooks inside dispatch jobs with explicit timeouts, structured errors, and cached results when the same hook is used by multiple conditions/templates in one execution.

### Elixir Module Hooks

```elixir
defmodule MyApp.DripDropHooks do
  @behaviour DripDrop.HookBehavior

  @impl true
  def handle_hook(:trial_days_remaining, enrollment, _context) do
    user = MyApp.Accounts.get_user!(enrollment.subscriber_id)
    days = Date.diff(user.trial_ends_at, Date.utc_today())
    {:ok, max(days, 0)}
  end

  @impl true
  def handle_hook(:feature_count, enrollment, _context) do
    count = MyApp.Features.count_enabled(enrollment.subscriber_id)
    {:ok, count}
  end
end

# Set on sequence
{:ok, sequence} = DripDrop.create_sequence(%{
  name: "Onboarding",
  key: "onboarding",
  hook_module: "MyApp.DripDropHooks"
})
```

### HTTP Hooks

```elixir
# Create HTTP hook (stores encrypted credentials)
{:ok, hook} = DripDrop.create_http_hook(sequence.id, %{
  name: "Get User Score",
  key: "user_score",
  method: "POST",
  url: "https://api.myapp.com/users/{{subscriber_id}}/score",
  auth_type: "bearer",
  auth_config: %{
    token: System.get_env("API_TOKEN")
  },
  body_template: ~s({"include_metadata": true}),
  response_path: "score",
  response_type: "number",
  timeout_ms: 5000,
  retry_count: 2
})

# Use in condition
DripDrop.create_condition(step.id, %{
  condition_type: "hook",
  http_hook_id: hook.id,
  operator: "gte",
  expected_value: "80"
})

# Use in template
# {{user_score}}
```

## Channel Implementations

Channel modules return structured results:

```elixir
{:ok, %{provider_message_id: "...", response: %{}}}
{:error, %{kind: :temporary | :permanent, reason: term()}}
```

Temporary errors retry. Permanent errors fail the execution and may write a suppression, depending on channel/provider event type.

### Link Shortening

Link shortening runs after template rendering and before channel delivery:

1. Render the template into channel-specific content.
2. Extract eligible links from HTML, text, SMS, Slack, Telegram, or webhook payloads.
3. Normalize and enrich each destination URL with configured tracking parameters.
4. Create or reuse short links through the configured short-link provider.
5. Replace the original URLs in the rendered payload.
6. Persist `short_links` rows tied to the `step_execution_id`.

Short-link generation is idempotent. DripDrop computes a stable idempotency key from the execution, original URL, destination URL, provider, and provider config. Retries reuse the existing `short_links` row instead of creating a new short link.

```elixir
defmodule DripDrop.ShortLinks.Adapter do
  @callback create_link(DripDrop.ShortLinks.Request.t(), keyword()) ::
              {:ok, DripDrop.ShortLinks.Result.t()}
              | {:error, %{kind: :temporary | :permanent, reason: term()}}
end
```

```elixir
%DripDrop.ShortLinks.Request{
  idempotency_key: "...",
  original_url: "https://example.com/pricing",
  destination_url: "https://example.com/pricing?utm_campaign=onboarding",
  tenant_key: "acct_123",
  channel: "email",
  sequence_key: "onboarding",
  step_key: "trial_reminder",
  metadata: %{
    "enrollment_id" => "...",
    "step_execution_id" => "..."
  }
}
```

Built-in provider shapes:

- `DripDrop.ShortLinks.Dub`: Calls Dub's create link API with `url`, `domain`, `key` or `prefix`, `externalId`, `tenantId`, `tagNames`, `comments`, `expiresAt`, and `trackConversion`.
- `DripDrop.ShortLinks.GoodAnalytics`: Calls the local `GoodAnalytics.create_link/1` library API. It creates tracked links in the host application's `good_analytics` schema and returns `https://domain/key` as the injected URL.
- `DripDrop.ShortLinks.Module`: Calls a user-provided Elixir module implementing `DripDrop.ShortLinks.Adapter`.
- `DripDrop.ShortLinks.Webhook`: Posts the request to an HTTP endpoint and expects a normalized short-link response.
- `DripDrop.ShortLinks.None`: Leaves URLs unchanged while still allowing UTM/enrichment if configured.

```elixir
config :dripdrop,
  short_links: [
    adapter: DripDrop.ShortLinks.Dub,
    domain: "go.example.com",
    track_conversion: true,
    tag_names: ["dripdrop"],
    external_id: :idempotency_key
  ]
```

GoodAnalytics library mode:

```elixir
config :dripdrop,
  short_links: [
    adapter: DripDrop.ShortLinks.GoodAnalytics,
    workspace_id: {MyApp.Workspaces, :current_good_analytics_workspace_id},
    domain: "go.example.com",
    key_strategy: :slug_from_idempotency_key,
    link_type: "campaign",
    utm_source: "dripdrop",
    utm_medium: :channel,
    external_id: :idempotency_key
  ]
```

The GoodAnalytics adapter maps a DripDrop short-link request to `GoodAnalytics.create_link/1`:

```elixir
%{
  workspace_id: request.workspace_id,
  domain: config.domain,
  key: generated_key,
  url: request.destination_url,
  link_type: "campaign",
  utm_source: "dripdrop",
  utm_medium: request.channel,
  utm_campaign: request.sequence_key,
  utm_content: request.step_key,
  external_id: request.idempotency_key,
  metadata: request.metadata
}
```

GoodAnalytics Pro is used through the webhook adapter unless DripDrop runs in the same BEAM/database as the Pro app. In the same app, use `DripDrop.ShortLinks.GoodAnalytics`; across app boundaries, use `DripDrop.ShortLinks.Webhook` pointed at the Pro API.

Shortening can be configured globally, per tenant, per sequence, per step, or per channel. Step-level configuration wins over sequence configuration, which wins over tenant/global defaults.

```elixir
DripDrop.create_step(v1.id, %{
  name: "Trial Reminder",
  key: "trial_reminder",
  channel: "email",
  timing: %{type: "delay", delay_amount: 3, delay_unit: "days"},
  config: %{
    "subject" => "Still evaluating?",
    "body" => ~s(<a href="https://example.com/pricing">Compare plans</a>),
    "short_links" => %{
      "enabled" => true,
      "provider" => "dub",
      "domain" => "go.example.com",
      "track_conversion" => true
    }
  }
})
```

Eligibility rules:

- Only `http` and `https` URLs are shortened.
- Already-shortened URLs from configured short domains are skipped.
- Unsubscribe, privacy policy, mailto, tel, signed, password reset, and one-time token links are excluded by default.
- Providers that require caller-supplied slugs, such as GoodAnalytics, generate deterministic keys from the idempotency key unless a step provides an explicit key strategy.
- HTML rewriting uses an HTML parser. Text rewriting uses URL tokenization that preserves trailing punctuation.
- If shortening fails with a temporary error, the dispatch follows the step retry policy. If it fails permanently, the step can either fail or send original URLs based on `short_links.on_error`.

### Email Channel

```elixir
defmodule DripDrop.Channels.Email do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, adapter) do
    credentials = adapter.credentials
    config = step.config
    
    email =
      Swoosh.Email.new()
      |> to(enrollment.data["email"])
      |> from(config["from"])
      |> subject(render_template(config["subject"], enrollment))
      |> html_body(render_template(config["body"], enrollment))
    
    case deliver_via_provider(email, adapter) do
      {:ok, _} -> {:ok, %{sent: true, provider: adapter.provider}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_via_provider(email, %{provider: "mailgun"} = adapter) do
    # Mailgun delivery
  end

  defp deliver_via_provider(email, %{provider: "sendgrid"} = adapter) do
    # SendGrid delivery
  end
end
```

### SMS Channel

```elixir
defmodule DripDrop.Channels.SMS do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, adapter) do
    phone = enrollment.data["phone"]
    body = render_template(step.config["body"], enrollment)
    
    case adapter.provider do
      "twilio" -> send_twilio(phone, body, adapter)
      "aws_sns" -> send_sns(phone, body, adapter)
    end
  end
end
```

### Webhook Channel

```elixir
defmodule DripDrop.Channels.Webhook do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, _adapter) do
    url = render_template(step.config["url"], enrollment)
    method = String.downcase(step.config["method"] || "post")
    body = render_template(step.config["body"], enrollment)
    
    opts = [
      method: String.to_atom(method),
      url: url,
      json: Jason.decode!(body)
    ]
    
    case Req.request(opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, %{status: status}}
      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### PubSub Channel

```elixir
defmodule DripDrop.Channels.PubSub do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, _adapter) do
    topic = render_template(step.config["topic"], enrollment)
    event = step.config["event"]
    payload = render_template(step.config["payload"], enrollment)
    
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      topic,
      {event, payload}
    )
    
    {:ok, %{broadcast: true, topic: topic}}
  end
end
```

### Slack Channel

```elixir
defmodule DripDrop.Channels.Slack do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, adapter) do
    webhook_url = adapter.credentials["webhook_url"]
    text = render_template(step.config["text"], enrollment)
    channel = step.config["channel"]
    
    payload = %{
      text: text,
      channel: channel
    }
    
    case Req.post(webhook_url, json: payload) do
      {:ok, %{status: 200}} -> {:ok, %{sent: true}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Telegram Channel

```elixir
defmodule DripDrop.Channels.Telegram do
  @behaviour DripDrop.Channel

  def deliver(step, enrollment, adapter) do
    bot_token = adapter.credentials["bot_token"]
    chat_id = enrollment.data["telegram_chat_id"]
    text = render_template(step.config["text"], enrollment)
    
    url = "https://api.telegram.org/bot#{bot_token}/sendMessage"
    
    payload = %{
      chat_id: chat_id,
      text: text,
      parse_mode: step.config["parse_mode"] || "Markdown"
    }
    
    case Req.post(url, json: payload) do
      {:ok, %{status: 200}} -> {:ok, %{sent: true}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Optional: Dashboard (Separate)

Following pgflow's approach - mount via router, not config flag.

### Router Integration

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import DripDrop.Web.Router

  # ... other routes

  scope "/admin" do
    pipe_through [:browser, :require_admin]
    
    dripdrop_dashboard("/dripdrop")
  end
end
```

### Implementation

```elixir
# lib/dripdrop/web/router.ex
defmodule DripDrop.Web.Router do
  defmacro dripdrop_dashboard(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      scope path, alias: false, as: false do
        import Phoenix.LiveView.Router
        
        live "/", DripDrop.Web.DashboardLive, :index
        live "/sequences", DripDrop.Web.SequencesLive, :index
        live "/sequences/:id", DripDrop.Web.SequenceDetailLive, :show
        live "/sequences/:id/edit", DripDrop.Web.SequenceEditLive, :edit
        live "/enrollments", DripDrop.Web.EnrollmentsLive, :index
        live "/executions", DripDrop.Web.ExecutionsLive, :index
        live "/adapters", DripDrop.Web.AdaptersLive, :index
        live "/hooks", DripDrop.Web.HooksLive, :index
      end
    end
  end
end
```

### Dashboard Features

- Sequences management (CRUD)
- Version control interface
- Step builder (visual workflow)
- Enrollment monitor
- Execution logs (success/failure/retry)
- Channel adapter management
- HTTP hooks configuration & testing
- Analytics (funnel, drop-off, performance)
- Template builder (if AI module enabled)

## Optional: AI Template Builder

Separate module requiring optional deps.

```elixir
# mix.exs - optional dependencies
{:req_llm, "~> 0.1", optional: true},
{:zoi, "~> 0.1", optional: true}
```

```elixir
# Only available if dependencies installed
defmodule DripDrop.TemplateBuilder.AI do
  def generate(description, opts \\ []) do
    available_variables = Keyword.fetch!(opts, :available_variables)
    template_engine = Keyword.get(opts, :template_engine, "liquid")
    provider = Keyword.get(opts, :provider, :anthropic)
    
    prompt = build_prompt(description, available_variables, template_engine)
    
    with {:ok, template} <- call_llm(prompt, provider),
         {:ok, validated} <- validate_template(template, template_engine) do
      {:ok, validated}
    end
  end
  
  defp call_llm(prompt, :anthropic) do
    # Use ReqLLM + Zoi for LLM calls
  end
  
  defp validate_template(template, "mjml") do
    # MJML validation with auto-fix
  end
  
  defp validate_template(template, "liquid") do
    # Liquid syntax validation
  end
end
```

## Messaging Policy

- **Suppression and consent**: Check unsubscribe, bounce, complaint, and manual suppression before every send. Store suppression at normalized recipient/channel scope.
- **Email authentication**: Applications using email channels must configure SPF, DKIM, and DMARC for sending domains. Bulk mail should include `List-Unsubscribe` and one-click unsubscribe headers where applicable.
- **Cold email limits**: Cold outbound should use separate domains/mailboxes from the primary domain, verify addresses before sending, keep bounce rate under 2%, and cap volume conservatively per inbox/domain. Default cold templates should be plain text.
- **Rate limits**: Add per-adapter, per-provider, per-domain, and per-recipient throttles. Provider APIs and inbox providers enforce limits differently.
- **Quiet hours and time zones**: Respect recipient timezone, local business-hour windows, weekends/holidays where configured, and daylight-saving transitions.
- **Inbound events**: Bounces, complaints, replies, unsubscribe clicks, webhook callbacks, and provider delivery events must feed `message_events` and may pause/cancel enrollments.
- **Auditability**: Store rendered payload snapshots, adapter used, provider response, and condition decisions for each execution. Avoid storing secrets in payload snapshots.
- **Data retention**: Provide cleanup/archive policies for events, rendered payloads, provider responses, and old PgFlow runs.
- **Security**: Encrypt adapter credentials and hook auth config, support key rotation, redact secrets from logs/telemetry, and avoid converting untrusted input to atoms.

## Implementation Boundaries

- Tenancy is represented by `tenant_key` where needed. If a host application uses account-level scoping, sequence keys, adapter defaults, suppressions, and enrollment uniqueness include the tenant scope.
- Dynamic customer-authored sequences use one stable PgFlow dispatch job and keep sequencing logic in DripDrop tables. Static developer-authored jobs or operational workflows can still use native PgFlow flows.
- Liquid/Solid is the default template engine for user-authored templates. EEx is reserved for trusted module templates.
- Provider webhook handling is part of the adapter contract. Email/SMS adapters normalize provider callbacks into `message_events` and update suppressions for bounces, complaints, and unsubscribes.
- Payload snapshots are retained for auditability with redaction. Applications handling sensitive data can disable payload snapshots or configure retention windows.

## Real-World Examples

### Example 1: SaaS Onboarding

```elixir
{:ok, sequence} = DripDrop.create_sequence(%{
  name: "SaaS User Onboarding",
  key: "saas_onboarding",
  hook_module: "MyApp.OnboardingHooks"
})

{:ok, v1} = DripDrop.create_sequence_version(sequence.id, %{
  version: 1,
  active: true
})

# Step 1: Welcome email (immediate)
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Welcome Email",
  key: "welcome",
  position: 1,
  channel: "email",
  timing: %{type: "immediate"},
  config: %{
    "subject" => "Welcome {{name}}!",
    "body" => "<mjml>...</mjml>"
  }
})

# Step 2: In-app notification (5 minutes later)
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Welcome Notification",
  key: "welcome_notification",
  position: 2,
  channel: "pubsub",
  timing: %{
    type: "delay",
    delay_amount: 5,
    delay_unit: "minutes"
  },
  config: %{
    "topic" => "user:{{subscriber_id}}",
    "event" => "notification",
    "payload" => %{
      "type" => "welcome",
      "message" => "Check out your dashboard!"
    }
  }
})

# Step 3: Setup reminder (1 day, only if incomplete)
{:ok, step3} = DripDrop.create_step(v1.id, %{
  name: "Setup Reminder",
  key: "setup_reminder",
  position: 3,
  channel: "email",
  timing: %{
    type: "delay",
    delay_amount: 1,
    delay_unit: "days"
  },
  config: %{
    "subject" => "Finish setup in 5 minutes",
    "body" => "..."
  }
})

DripDrop.create_condition(step3.id, %{
  condition_type: "hook",
  hook_function: "setup_completed",
  operator: "eq",
  expected_value: "false"
})

# Step 4: Weekly digest (every Monday at 9am)
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Weekly Digest",
  key: "weekly_digest",
  position: 4,
  channel: "email",
  timing: %{
    type: "cron",
    cron_expression: "every monday at 9am",
    timezone: "America/New_York"
  },
  config: %{
    "subject" => "Your weekly summary",
    "body" => "..."
  }
})

# Step 5: SMS reminder (7 days, high-value users only)
{:ok, sms_step} = DripDrop.create_step(v1.id, %{
  name: "Activation SMS",
  key: "activation_sms",
  position: 5,
  channel: "sms",
  timing: %{
    type: "delay",
    delay_amount: 7,
    delay_unit: "days"
  },
  config: %{
    "body" => "Hi {{name}}! You've completed {{progress}}% of setup."
  }
})

DripDrop.create_condition(sms_step.id, %{
  condition_type: "enrollment_data",
  field_path: "plan_tier",
  operator: "eq",
  expected_value: "enterprise"
})

# Enroll user
DripDrop.enroll(
  sequence_key: "saas_onboarding",
  subscriber: %{type: "User", id: user.id},
  data: %{
    name: user.name,
    email: user.email,
    phone: user.phone,
    plan_tier: "enterprise"
  }
)
```

### Example 2: CRM Email Sequence

```elixir
{:ok, sequence} = DripDrop.create_sequence(%{
  name: "Lead Nurture",
  key: "lead_nurture"
})

{:ok, v1} = DripDrop.create_sequence_version(sequence.id, %{version: 1, active: true})

# HTTP Hook: Get lead score from Zapier/n8n
{:ok, score_hook} = DripDrop.create_http_hook(sequence.id, %{
  name: "Lead Score",
  key: "lead_score",
  method: "POST",
  url: "https://hooks.zapier.com/hooks/catch/YOUR_WEBHOOK/",
  body_template: ~s({"email": "{{email}}"}),
  response_path: "score",
  response_type: "number"
})

# Step 1: Initial outreach
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Initial Email",
  position: 1,
  channel: "email",
  timing: %{type: "immediate"},
  config: %{
    "subject" => "Quick question about {{company_name}}",
    "body" => "..."
  }
})

# Step 2: Hot lead path (score >= 70)
{:ok, hot_step} = DripDrop.create_step(v1.id, %{
  name: "Enterprise Pitch",
  position: 2,
  channel: "email",
  timing: %{type: "delay", delay_amount: 3, delay_unit: "days"},
  config: %{"subject" => "...", "body" => "..."}
})

DripDrop.create_condition(hot_step.id, %{
  http_hook_id: score_hook.id,
  operator: "gte",
  expected_value: "70"
})

# Step 3: Notify sales via Slack
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Notify Sales",
  position: 3,
  channel: "slack",
  timing: %{type: "delay", delay_amount: 3, delay_unit: "days"},
  config: %{
    "channel" => "#sales",
    "text" => "🔥 Hot lead: {{name}} at {{company_name}} (score: {{lead_score}})"
  }
})

# Step 4: Update CRM via webhook
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Update CRM",
  position: 4,
  channel: "webhook",
  timing: %{type: "delay", delay_amount: 14, delay_unit: "days"},
  config: %{
    "url" => "https://crm.myapp.com/api/leads/{{subscriber_id}}",
    "method" => "PATCH",
    "body" => ~s({"status": "unresponsive"})
  }
})
```

### Example 3: Multi-Channel Notification

```elixir
# Same message, multiple channels
{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Trial Ending - Email",
  channel: "email",
  timing: %{type: "delay", delay_amount: 13, delay_unit: "days"},
  config: %{"subject" => "Trial ends tomorrow", "body" => "..."}
})

{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Trial Ending - SMS",
  channel: "sms",
  timing: %{type: "delay", delay_amount: 13, delay_unit: "days"},
  config: %{"body" => "Your trial ends tomorrow. Upgrade to keep access!"}
})

{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Trial Ending - In-App",
  channel: "pubsub",
  timing: %{type: "delay", delay_amount: 13, delay_unit: "days"},
  config: %{
    "topic" => "user:{{subscriber_id}}",
    "event" => "alert",
    "payload" => %{"type" => "trial_ending", "days": 1}
  }
})

{:ok, _} = DripDrop.create_step(v1.id, %{
  name: "Trial Ending - Telegram",
  channel: "telegram",
  timing: %{type: "delay", delay_amount: 13, delay_unit: "days"},
  config: %{
    "text" => "⚠️ Your trial ends tomorrow! Upgrade now: {{upgrade_url}}"
  }
})
```

## Installation

```elixir
# mix.exs
def deps do
  [
    {:dripdrop, "~> 0.1"},
    {:ecto_evolver, "~> 0.1"},
    {:pgflow, "~> 0.1"},
    {:crontab, "~> 1.1"},
    {:cloak_ecto, "~> 1.2"},
    {:req, "~> 0.4"},
    
    # Optional
    {:dripdrop_web, "~> 0.1", optional: true},
    {:swoosh, "~> 1.0", optional: true},
    {:solid, "~> 0.14", optional: true},
    {:mjml, "~> 2.0", optional: true},
    {:req_llm, "~> 0.1", optional: true},
    {:zoi, "~> 0.1", optional: true}
  ]
end
```

```elixir
# config/config.exs
config :dripdrop,
  repo: MyApp.Repo,
  schema: "dripdrop",
  scheduler: DripDrop.Schedulers.Pgflow

# Generate encryption key
# mix dripdrop.gen.key
config :dripdrop, DripDrop.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1",
      key: Base.decode64!(System.get_env("DRIPDROP_ENCRYPTION_KEY"))
    }
  ]
```

```bash
# Setup
mix pgflow.gen.postgres_extensions_migration
mix pgflow.gen.pgmq_migration
mix pgflow.setup
mix pgflow.gen.job_migration DripDrop.Jobs.DispatchStep
mix dripdrop.setup
mix ecto.migrate
```

## API

```elixir
# Sequences
DripDrop.create_sequence(attrs)
DripDrop.create_sequence_version(sequence_id, attrs)
DripDrop.create_step(version_id, attrs)
DripDrop.create_condition(step_id, attrs)

# Channel Adapters
DripDrop.create_channel_adapter(attrs)
DripDrop.list_channel_adapters(channel)
DripDrop.get_default_adapter(channel)

# HTTP Hooks
DripDrop.create_http_hook(sequence_id, attrs)
DripDrop.test_http_hook(hook_id, test_data)

# Enrollments
DripDrop.enroll(opts)
DripDrop.unenroll(sequence_key, subscriber_type, subscriber_id)
DripDrop.pause_enrollment(enrollment_id)
DripDrop.resume_enrollment(enrollment_id)

# Events
DripDrop.track_event(enrollment_id, event_key, event_data \\ %{})

# Queries
DripDrop.get_enrollment(sequence_key, subscriber_type, subscriber_id)
DripDrop.list_active_enrollments(sequence_key)
```

## Architecture Summary

- **Database**: Isolated `dripdrop` schema via ecto_evolver raw SQL migrations
- **Execution**: PgFlow owns the `pgflow` schema and runs DripDrop dispatch jobs/flows
- **Timing**: Crontab for validation/parsing; PgFlow/pg_cron or dispatch jobs for execution
- **Channels**: Email, SMS, Webhook, PubSub, Slack, Telegram (extensible)
- **Adapters**: Database-stored with encrypted credentials, multiple per channel
- **Hooks**: Elixir modules OR HTTP endpoints (n8n, Zapier, APIs)
- **Templates**: Liquid, MJML, Mustache, EEx
- **Short links**: Pluggable providers for Dub, GoodAnalytics, custom Elixir modules, webhooks, or no-op rewriting
- **Dashboard**: Optional LiveView mount via router (pgflow pattern)
- **AI Builder**: Optional module with ReqLLM + Zoi
- **Messaging policy**: Branching transitions, suppression/consent, idempotent dispatch, provider events, rate limits, quiet hours, key rotation, data retention
