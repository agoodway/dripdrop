defmodule DripDrop.Vault do
  @moduledoc """
  Cloak vault used for encrypted DripDrop credential fields.
  """

  use Cloak.Vault, otp_app: :dripdrop

  @env_key "DRIPDROP_ENCRYPTION_KEY"
  @key_bytes 32

  @impl GenServer
  def init(config) do
    if pre_configured_ciphers?(config) do
      {:ok, config}
    else
      apply_env_key(config)
    end
  end

  defp pre_configured_ciphers?(config) do
    case Keyword.get(config, :ciphers) do
      nil -> false
      [] -> false
      _ciphers -> true
    end
  end

  defp apply_env_key(config) do
    case decode_env_key() do
      {:ok, key} ->
        config =
          Keyword.put(config, :ciphers,
            default: {
              Cloak.Ciphers.AES.GCM,
              tag: "AES.GCM.V1", key: key
            }
          )

        {:ok, config}

      {:error, reason} ->
        {:stop, {:invalid_encryption_key, reason}}
    end
  end

  @doc """
  Decodes `DRIPDROP_ENCRYPTION_KEY` from base64 into a 32-byte AES key.
  """
  @spec decode_env_key() ::
          {:ok, binary()} | {:error, :missing | :invalid_base64 | :invalid_length}
  def decode_env_key do
    with {:ok, encoded} <- fetch_env_key(),
         {:ok, decoded} <- decode_base64(encoded),
         :ok <- validate_length(decoded) do
      {:ok, decoded}
    end
  end

  defp fetch_env_key do
    case System.get_env(@env_key) do
      nil -> {:error, :missing}
      "" -> {:error, :missing}
      value -> {:ok, value}
    end
  end

  defp decode_base64(encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp validate_length(decoded) when byte_size(decoded) == @key_bytes, do: :ok
  defp validate_length(_decoded), do: {:error, :invalid_length}
end
