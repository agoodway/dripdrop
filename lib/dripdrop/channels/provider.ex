defmodule DripDrop.Channels.Provider do
  @moduledoc """
  Convenience macro and validation helpers for provider modules.
  """

  @doc """
  Installs default `DripDrop.Channel` callbacks for a provider module.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    required_credentials = Keyword.get(opts, :required_credentials, [])

    quote bind_quoted: [required_credentials: Macro.escape(required_credentials)] do
      @behaviour DripDrop.Channel
      @required_credentials required_credentials

      import DripDrop.Channels.Provider, only: [missing_credentials: 2]

      @doc """
      Validates provider credentials against the required credential list.
      """
      @spec validate_credentials(map()) :: :ok | {:error, [{atom(), binary()}]}
      @impl DripDrop.Channel
      def validate_credentials(credentials) when is_map(credentials) do
        missing_credentials(credentials, @required_credentials)
      end

      def validate_credentials(_credentials), do: {:error, [credentials: "must be a map"]}

      @doc """
      Returns provider webhook routes.
      """
      @spec webhook_routes(map()) :: [DripDrop.Channel.webhook_route()]
      @impl DripDrop.Channel
      def webhook_routes(_adapter), do: []

      @doc """
      Verifies a provider webhook signature.
      """
      @spec verify_signature(map(), map()) :: :ok | {:error, term()}
      @impl DripDrop.Channel
      def verify_signature(_adapter, _request), do: {:error, :unsupported_signature}

      @doc """
      Delivers a step for this provider.
      """
      @spec deliver(map(), map(), map()) :: {:ok, map()} | {:error, map()}
      @impl DripDrop.Channel
      def deliver(_step, _enrollment, _adapter) do
        {:error, %{kind: :permanent, reason: :provider_not_implemented}}
      end

      defoverridable deliver: 3, validate_credentials: 1, webhook_routes: 1, verify_signature: 2
    end
  end

  @doc """
  Returns credential errors for required keys that are absent or blank.
  """
  @spec missing_credentials(map(), [atom()]) :: :ok | {:error, [{atom(), binary()}]}
  def missing_credentials(credentials, required_credentials) do
    errors =
      required_credentials
      |> Enum.reject(&present?(credentials, &1))
      |> Enum.map(&{&1, "is required"})

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp present?(credentials, key) do
    Map.get(credentials, key) not in [nil, ""] or
      Map.get(credentials, to_string(key)) not in [nil, ""]
  end
end
