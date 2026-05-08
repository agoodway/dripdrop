System.put_env("DRIPDROP_ENCRYPTION_KEY", "UKVpehsGQVfTYKrgsl5GeGuosauyJu2vwQuJVZMoCcU=")

ExUnit.start(exclude: [:integration])

{:ok, _pid} = DripDrop.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(DripDrop.TestRepo, :manual)
