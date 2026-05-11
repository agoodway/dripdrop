# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dripdrop_demo,
  ecto_repos: [DripdropDemo.Repo],
  generators: [timestamp_type: :utc_datetime],
  demo_time_scale: 0.0001,
  mock_hooks_port: 4013

config :dripdrop,
  repo: DripdropDemo.Repo,
  scheduler: DripDrop.Schedulers.Pgflow,
  channels: [:email, :sms, :webhook, :pubsub, :slack, :telegram],
  quiet_hours_default: false,
  sms_max_chars: 1600,
  http_hook_allow_http: true,
  http_hook_allow_private: true,
  unsubscribe_secret:
    System.get_env("DRIPDROP_DEMO_UNSUBSCRIBE_SECRET") ||
      :crypto.hash(:sha256, "dripdrop-demo-local-unsubscribe") |> Base.encode16(case: :lower),
  unsubscribe_url_builder: {DripdropDemo.Unsubscribe, :build_url},
  unsubscribe_mailto: "unsubscribe@dripdrop.dev"

config :dripdrop, :pgflow, jobs: [DripDrop.Jobs.DispatchStep, DripDrop.Jobs.CronTick]

config :dripdrop, DripDrop.Vault,
  ciphers: [
    default: {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1", key: Base.decode64!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    }
  ]

# Configure the endpoint
config :dripdrop_demo, DripdropDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DripdropDemoWeb.ErrorHTML, json: DripdropDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DripdropDemo.PubSub,
  live_view: [signing_salt: "BN3Xb1gK"]

# Configure the mailer for local-only synthetic email rendering.
config :dripdrop_demo, DripdropDemo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dripdrop_demo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  dripdrop_demo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
