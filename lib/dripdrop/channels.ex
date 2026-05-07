defmodule DripDrop.Channels do
  @moduledoc """
  Registry and lookup helpers for built-in and host-registered channel providers.
  """

  alias DripDrop.{Channel, Helpers}
  alias DripDrop.Channels

  @registry_key {__MODULE__, :providers}

  @built_in %{
    email: %{
      mailgun: Channels.Email.Mailgun,
      sendgrid: Channels.Email.SendGrid,
      postmark: Channels.Email.Postmark,
      mailersend: Channels.Email.MailerSend,
      ses: Channels.Email.SES,
      smtp: Channels.Email.SMTP,
      gmail: Channels.Email.Gmail,
      ms365: Channels.Email.Ms365
    },
    sms: %{
      twilio: Channels.SMS.Twilio,
      aws_sns: Channels.SMS.AwsSns
    },
    webhook: %{
      default: Channels.Webhook.Default
    },
    pubsub: %{
      phoenix_pubsub: Channels.PubSub.PhoenixPubSub
    },
    slack: %{
      webhook: Channels.Slack.Webhook
    },
    telegram: %{
      bot_api: Channels.Telegram.BotAPI
    },
    whatsapp: %{
      cloud_api: Channels.WhatsApp.CloudAPI
    }
  }

  @doc """
  Registers a host-defined channel provider.
  """
  @spec register(atom() | binary(), atom() | binary(), module()) :: :ok | {:error, term()}
  def register(channel, provider, module) when is_atom(module) do
    with {:ok, channel} <- normalize_key(channel),
         {:ok, provider} <- normalize_key(provider),
         :ok <- ensure_channel_module(module) do
      providers =
        @registry_key
        |> :persistent_term.get(%{})
        |> Map.update(channel, %{provider => module}, &Map.put(&1, provider, module))

      :persistent_term.put(@registry_key, providers)
      :ok
    end
  end

  def register(_channel, _provider, _module), do: {:error, :invalid_module}

  @doc """
  Returns all known channel keys.
  """
  @spec channels() :: [atom()]
  def channels do
    @built_in
    |> Map.keys()
    |> Enum.concat(Map.keys(custom_providers()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns all known provider keys for a channel.
  """
  @spec providers(atom() | binary()) :: [atom()]
  def providers(channel) do
    case normalize_key(channel) do
      {:ok, channel} ->
        @built_in
        |> Map.get(channel, %{})
        |> Map.merge(Map.get(custom_providers(), channel, %{}))
        |> Map.keys()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @doc """
  Looks up the module for a channel/provider pair.
  """
  @spec provider_module(atom() | binary(), atom() | binary()) ::
          {:ok, module()} | {:error, term()}
  def provider_module(channel, provider) do
    with {:ok, channel} <- normalize_key(channel),
         {:ok, provider} <- normalize_key(provider) do
      module =
        custom_providers()
        |> get_in([channel, provider])
        |> case do
          nil -> get_in(@built_in, [channel, provider])
          module -> module
        end

      if module, do: {:ok, module}, else: {:error, :unknown_provider}
    else
      :error -> {:error, :unknown_provider}
    end
  end

  @doc """
  Normalizes channel and provider keys into existing atoms.
  """
  @spec normalize_key(atom() | binary()) :: {:ok, atom()} | :error
  def normalize_key(key) when is_atom(key), do: {:ok, key}

  def normalize_key(key) when is_binary(key) do
    case key |> Helpers.slugify_key() |> Helpers.atom_or_string() do
      atom when is_atom(atom) -> {:ok, atom}
      _binary -> :error
    end
  end

  def normalize_key(_key), do: :error

  defp ensure_channel_module(module) do
    with true <- Code.ensure_loaded?(module),
         [] <- missing_callbacks(module) do
      :ok
    else
      false -> {:error, :module_not_loaded}
      missing -> {:error, {:missing_callbacks, missing}}
    end
  end

  defp missing_callbacks(module) do
    Channel.behaviour_info(:callbacks)
    |> Enum.reject(fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp custom_providers, do: :persistent_term.get(@registry_key, %{})
end
