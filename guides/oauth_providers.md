# OAuth Providers

Gmail and MS365 adapters use host-owned `token_callback` and `user_email`
credentials. DripDrop sends with access tokens but does not read OAuth client
secrets, persist refresh tokens, or make refresh requests.

## Callback Contract

The callback can be an arity-1 function, `{Module, :function}`, an arity-0
function, or `{Module, :function, args}`. Arity-1 callbacks receive the channel
adapter. Return values can be a bare token string, `%{access_token: token}`,
`%{"access_token" => token}`, `%{token: token}`, or `%{"token" => token}`.
Expiration can be `expires_at`, `expires_in`, or omitted.

```elixir
{:ok, %{access_token: "ya29...", expires_at: DateTime.utc_now() |> DateTime.add(3600)}}
```

or an error:

```elixir
{:error, :revoked}
```

DripDrop caches successful tokens by adapter and provider until expiry. The
callback is not invoked while a cached token is valid; tokens without a valid
expiry are cached for five minutes.

## Hand-Rolled Req Example

```elixir
defmodule MyApp.GoogleTokens do
  def token(_adapter) do
    {:ok, %{body: body}} =
      Req.post("https://oauth2.googleapis.com/token",
        form: [
          grant_type: "refresh_token",
          refresh_token: System.fetch_env!("GOOGLE_REFRESH_TOKEN"),
          client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
          client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET")
        ]
      )

    {:ok, %{access_token: body["access_token"], expires_at: DateTime.add(DateTime.utc_now(), body["expires_in"])}}
  end
end
```

## Tango Example

Tango is a recommended companion library, not a DripDrop dependency.

```elixir
defmodule MyApp.TangoTokens do
  def token(adapter) do
    connection_id = adapter.credentials["oauth_connection_id"]

    with {:ok, connection} <- Tango.Connection.get_by_external_id(connection_id),
         {:ok, token} <- Tango.Connection.access_token(connection) do
      {:ok, %{access_token: token.value, expires_at: token.expires_at}}
    end
  end
end
```

## Ueberauth Example

Use Ueberauth for login/consent and a host-owned refresh job for token storage.
The callback should only fetch the current access token from host storage:

```elixir
defmodule MyApp.UeberauthTokens do
  def token(adapter) do
    identity = adapter.credentials["oauth_identity"]

    case MyApp.OAuthTokens.current(identity, :google) do
      nil -> {:error, :revoked}
      token -> {:ok, %{access_token: token.access_token, expires_at: token.expires_at}}
    end
  end
end
```
