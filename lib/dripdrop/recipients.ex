defmodule DripDrop.Recipients do
  @moduledoc """
  Normalizes channel recipient identifiers for matching and policy checks.

  Phone numbers use `ExPhoneNumber`/libphonenumber when the input can be parsed
  for the configured default region, falling back to conservative digit cleanup
  for incomplete fixture or provider-supplied values. Email addresses are trimmed
  and downcased for operational suppression matching.
  """

  @default_region "US"

  @doc """
  Normalizes a recipient value for a DripDrop channel.
  """
  @spec normalize(atom() | binary(), binary(), keyword()) :: binary()
  def normalize(channel, recipient, opts \\ [])

  def normalize(channel, recipient, _opts) when channel in [:email, "email"] do
    recipient
    |> String.trim()
    |> String.downcase()
  end

  def normalize(channel, recipient, opts)
      when channel in [:sms, "sms", :whatsapp, "whatsapp"] do
    default_region = Keyword.get(opts, :default_region, @default_region)

    case normalize_phone(recipient, default_region) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> fallback_phone_normalize(recipient)
    end
  end

  def normalize(channel, recipient, _opts) when channel in [:webhook, "webhook"] do
    String.trim(recipient)
  end

  def normalize(channel, recipient, _opts)
      when channel in [:slack, "slack", :telegram, "telegram"] do
    recipient
    |> String.trim()
    |> String.downcase()
  end

  def normalize(_channel, recipient, _opts), do: String.trim(recipient)

  @doc """
  Returns true when an email address passes ExEmail syntax validation.
  """
  @spec valid_email?(binary()) :: boolean()
  def valid_email?(email) when is_binary(email) do
    email
    |> String.trim()
    |> ExEmail.validate()
    |> case do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  def valid_email?(_email), do: false

  @doc """
  Parses and formats a phone number as E.164.
  """
  @spec normalize_phone(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def normalize_phone(phone, default_region \\ @default_region)

  def normalize_phone(phone, default_region) when is_binary(phone) do
    with {:ok, phone_number} <- ExPhoneNumber.parse(phone, default_region),
         true <- ExPhoneNumber.is_valid_number?(phone_number) do
      {:ok, ExPhoneNumber.format(phone_number, :e164)}
    else
      false -> {:error, :invalid_phone_number}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_phone(_phone, _default_region), do: {:error, :invalid_phone_number}

  defp fallback_phone_normalize(recipient) do
    recipient
    |> String.trim()
    |> String.replace(~r/[^\d+]/, "")
    |> normalize_us_phone_digits()
  end

  defp normalize_us_phone_digits("+" <> _rest = recipient), do: recipient
  defp normalize_us_phone_digits("1" <> rest) when byte_size(rest) == 10, do: "+1#{rest}"
  defp normalize_us_phone_digits(recipient) when byte_size(recipient) == 10, do: "+1#{recipient}"
  defp normalize_us_phone_digits(recipient), do: recipient
end
