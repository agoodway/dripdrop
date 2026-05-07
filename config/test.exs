import Config

config :logger, level: :warning

config :dripdrop, ecto_repos: [DripDrop.TestRepo]

config :dripdrop, DripDrop.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("DRIPDROP_DB_PORT", "54325")),
  database: "dripdrop_dev",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/priv/repo"

config :dripdrop, DripDrop.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("UKVpehsGQVfTYKrgsl5GeGuosauyJu2vwQuJVZMoCcU=")}
  ]

config :dripdrop,
  repo: DripDrop.TestRepo,
  scheduler: DripDrop.Schedulers.Test,
  channels: [],
  bounce_complaint_thresholds: [enabled: false],
  dev_server_port: 4011,
  # Tests use http://example.com fixtures and Req.Test stubs that don't actually
  # hit the network. Production callers default to https-only.
  http_hook_allow_http: true
