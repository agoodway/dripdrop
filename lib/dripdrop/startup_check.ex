defmodule DripDrop.StartupCheck do
  @moduledoc """
  Validates host configuration before DripDrop starts dispatching messages.
  """

  require Logger

  alias DripDrop.{Config, Jobs, Schedulers, Step, Vault}
  alias DripDrop.Policy.UnsubscribeHeaders

  import Ecto.Query

  @type error ::
          {:missing_optional_dependency, atom(), atom()}
          | {:invalid_encryption_key, term()}
          | {:invalid_scheduler, module()}
          | :unsubscribe_url_builder_unconfigured
          | {:pgflow_job_not_registered, module()}

  @optional_deps %{
    email: [:swoosh, :finch],
    sms: [],
    webhook: [:req],
    pubsub: [:phoenix_pubsub],
    slack: [:req],
    telegram: [:ex_gram],
    whatsapp: [:whatsapp_sdk]
  }

  @doc """
  Validates optional dependencies and runtime configuration needed by DripDrop.
  """
  @spec run() :: :ok | {:error, [error()]}
  def run do
    errors =
      []
      |> Kernel.++(optional_dependency_errors())
      |> Kernel.++(encryption_key_errors())
      |> Kernel.++(scheduler_errors())
      |> Kernel.++(unsubscribe_header_errors())
      |> Kernel.++(pgflow_registration_errors())

    case errors do
      [] ->
        :ok

      errors ->
        Enum.each(errors, &log_error/1)
        {:error, errors}
    end
  end

  defp optional_dependency_errors do
    :dripdrop
    |> Application.get_env(:channels, [])
    |> Enum.flat_map(&missing_deps_for_channel/1)
  end

  defp missing_deps_for_channel(channel) do
    channel_atom = Config.to_existing_atom(channel)

    channel_atom
    |> optional_deps()
    |> Enum.reject(&loaded_application?/1)
    |> Enum.map(&{:missing_optional_dependency, channel_atom, &1})
  end

  defp optional_deps(nil), do: []
  defp optional_deps(channel), do: Map.get(@optional_deps, channel, [])

  defp loaded_application?(app) do
    Code.ensure_loaded?(application_module(app)) or Application.ensure_loaded(app) == :ok
  end

  defp application_module(:swoosh), do: Swoosh
  defp application_module(:finch), do: Finch
  defp application_module(:req), do: Req
  defp application_module(:phoenix_pubsub), do: Phoenix.PubSub
  defp application_module(app), do: Module.concat([Macro.camelize(to_string(app))])

  defp encryption_key_errors do
    if configured_vault_ciphers?() do
      []
    else
      case Vault.decode_env_key() do
        {:ok, _key} -> []
        {:error, reason} -> [{:invalid_encryption_key, reason}]
      end
    end
  end

  defp configured_vault_ciphers? do
    case Application.get_env(:dripdrop, Vault, []) |> Keyword.get(:ciphers) do
      nil -> false
      [] -> false
      _ciphers -> true
    end
  end

  defp scheduler_errors do
    scheduler = Application.get_env(:dripdrop, :scheduler, Schedulers.Pgflow)

    if Code.ensure_loaded?(scheduler) and
         function_exported?(scheduler, :schedule, 2) and
         function_exported?(scheduler, :cancel, 1) do
      []
    else
      [{:invalid_scheduler, scheduler}]
    end
  end

  defp pgflow_registration_errors do
    if pgflow_scheduler?() and Code.ensure_loaded?(PgFlow) and not job_registered?() do
      [{:pgflow_job_not_registered, Jobs.DispatchStep}]
    else
      []
    end
  end

  defp pgflow_scheduler? do
    Application.get_env(:dripdrop, :scheduler, Schedulers.Pgflow) == Schedulers.Pgflow
  end

  defp job_registered? do
    config = Application.get_env(:dripdrop, :pgflow, [])
    jobs = Keyword.get(config, :jobs, [])
    Jobs.DispatchStep in jobs
  end

  defp unsubscribe_header_errors do
    if unsubscribe_header_steps?() and not UnsubscribeHeaders.configured?() do
      [:unsubscribe_url_builder_unconfigured]
    else
      []
    end
  end

  defp unsubscribe_header_steps? do
    repo = Application.get_env(:dripdrop, :repo)

    if repo do
      Step
      |> where([step], step.channel == "email")
      |> where(
        [step],
        fragment(
          """
          coalesce(?->>'unsubscribe_headers', 'false') = 'true'
          OR coalesce(?->>'unsubscribe', 'false') = 'true'
          OR coalesce(?->'email'->>'unsubscribe_headers', 'false') = 'true'
          """,
          step.config,
          step.config,
          step.config
        )
      )
      |> limit(1)
      |> repo.exists?()
    else
      false
    end
  rescue
    _exception -> false
  end

  defp log_error({:pgflow_job_not_registered, job}) do
    Logger.warning("DripDrop startup check: #{inspect(job)} is not registered with PgFlow")
  end

  defp log_error(error) do
    Logger.error("DripDrop startup check failed: #{inspect(error)}")
  end
end
