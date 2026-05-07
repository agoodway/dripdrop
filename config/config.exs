import Config

config :swoosh, :api_client, Swoosh.ApiClient.Req

config :dripdrop, DripDrop.Cache,
  gc_interval: :timer.hours(1),
  max_size: 100_000

config :dripdrop,
  repo: nil,
  schema: "dripdrop",
  scheduler: DripDrop.Schedulers.Pgflow,
  redaction_patterns: [
    ~r/(api[_-]?key|token|secret|password|authorization)(["']?\s*(?::|=>|=)\s*["']?)[^"',\s}]+/i,
    ~r/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/i
  ],
  sms_max_chars: 1600,
  quiet_hours_default: {8, 21},
  quiet_hours_timezones: [],
  rate_limits: [],
  rate_limit_backend: DripDrop.Policy.RateLimit.Postgres,
  dispatch_concurrency: [
    channel: %{},
    adapter: %{},
    defer_seconds: 30
  ],
  bounce_complaint_thresholds: [
    enabled: true,
    interval_ms: 60_000,
    window_days: 30,
    complaint_rate: 0.003,
    bounce_rate: 0.02,
    pause_seconds: 86_400
  ],
  default_timezone: "Etc/UTC",
  unsubscribe_url_builder: nil,
  unsubscribe_mailto: "unsubscribe@example.com",
  channels: [],
  short_links: [
    registry: DripDrop.ShortLinks.Registry,
    enabled: false,
    provider: DripDrop.ShortLinks.None,
    exclude_patterns: [
      ~r/unsubscribe/i,
      ~r/privacy/i,
      ~r/password[_-]?reset/i,
      ~r/token=/i,
      ~r/signature=/i
    ],
    on_error: :fail
  ]

import_config "#{config_env()}.exs"
