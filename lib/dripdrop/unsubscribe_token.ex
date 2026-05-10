defmodule DripDrop.UnsubscribeToken do
  @moduledoc """
  Signs and verifies one-click unsubscribe tokens.
  """

  @salt "dripdrop unsubscribe"
  @default_max_age 60 * 60 * 24 * 60

  @type payload :: %{
          required(:channel) => String.t(),
          required(:recipient) => String.t(),
          optional(:tenant_key) => String.t() | nil
        }

  @doc """
  Signs an unsubscribe payload into a tamper-resistant token.
  """
  @spec sign(payload()) :: {:ok, String.t()} | {:error, :missing_unsubscribe_secret}
  def sign(payload) when is_map(payload) do
    case secret() do
      {:ok, secret} -> {:ok, Plug.Crypto.sign(secret, @salt, payload)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies an unsubscribe token and returns the signed payload.
  """
  @spec verify(String.t()) :: {:ok, payload()} | {:error, term()}
  def verify(token) when is_binary(token) do
    case secret() do
      {:ok, secret} -> Plug.Crypto.verify(secret, @salt, token, max_age: max_age())
      {:error, reason} -> {:error, reason}
    end
  end

  defp secret do
    case Application.get_env(:dripdrop, :unsubscribe_secret) do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _missing -> {:error, :missing_unsubscribe_secret}
    end
  end

  defp max_age do
    Application.get_env(:dripdrop, :unsubscribe_token_max_age, @default_max_age)
  end
end
