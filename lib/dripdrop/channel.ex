defmodule DripDrop.Channel do
  @moduledoc """
  Uniform contract implemented by DripDrop channel providers.
  """

  @type delivery_success :: %{
          optional(:provider_message_id) => binary() | nil,
          optional(:response) => map()
        }

  @type error_kind :: :temporary | :permanent
  @type delivery_error :: %{kind: error_kind(), reason: term()}
  @type credential_errors :: [{atom(), binary()}]
  @type webhook_route :: {atom(), binary(), module()}

  @callback deliver(Ecto.Schema.t(), term(), Ecto.Schema.t()) ::
              {:ok, delivery_success()} | {:error, delivery_error()}

  @callback validate_credentials(map()) :: :ok | {:error, credential_errors()}

  @callback webhook_routes(Ecto.Schema.t()) :: [webhook_route()]

  @callback verify_signature(Ecto.Schema.t(), term()) :: :ok | {:error, term()}
end
