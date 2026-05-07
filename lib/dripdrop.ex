defmodule DripDrop do
  @moduledoc """
  Public entry point for DripDrop.

  DripDrop is a backend-first, database-driven messaging sequence engine. The
  foundation currently exposes boot-time validation while the domain APIs are
  implemented capability by capability.
  """

  alias DripDrop.{
    Channel,
    ChannelAdapters,
    Dispatch,
    Enrollments,
    HttpHooks,
    SequenceAuthoring,
    StartupCheck,
    Suppressions,
    Web
  }

  @doc """
  Validates the host application's DripDrop runtime configuration.

  This check is intended for host `Application.start/2` callbacks after the
  host Repo, PgFlow supervisor, and custom channel registrations have been
  configured.
  """
  @spec startup_check() :: :ok | {:error, [StartupCheck.error()]}
  defdelegate startup_check, to: StartupCheck, as: :run

  @doc "Creates a sequence."
  @spec create_sequence(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_sequence(attrs), to: SequenceAuthoring

  @doc "Creates a sequence version."
  @spec create_sequence_version(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_sequence_version(sequence_id, attrs), to: SequenceAuthoring

  @doc "Activates a sequence version and archives the previously active version."
  @spec activate_sequence_version(Ecto.UUID.t()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate activate_sequence_version(version_id), to: SequenceAuthoring

  @doc "Creates a step in a sequence version."
  @spec create_step(Ecto.UUID.t(), map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_step(version_id, attrs), to: SequenceAuthoring

  @doc "Creates a transition in a sequence version."
  @spec create_step_transition(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_step_transition(version_id, attrs), to: SequenceAuthoring

  @doc "Creates a condition attached to a step by default, or to a transition when `transition_id` is provided."
  @spec create_condition(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_condition(owner_id, attrs), to: SequenceAuthoring

  @doc "Validates a sequence version before activation."
  @spec validate_sequence_version(Ecto.UUID.t()) :: {:ok, Ecto.Schema.t()} | {:error, list()}
  defdelegate validate_sequence_version(version_id), to: SequenceAuthoring

  @doc "Creates a channel adapter."
  @spec create_channel_adapter(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_channel_adapter(attrs), to: ChannelAdapters

  @doc "Updates a channel adapter."
  @spec update_channel_adapter(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_channel_adapter(adapter, attrs), to: ChannelAdapters

  @doc "Lists channel adapters."
  @spec list_channel_adapters(map()) :: [Ecto.Schema.t()]
  defdelegate list_channel_adapters(filters \\ %{}), to: ChannelAdapters

  @doc "Gets the active default adapter for a channel and tenant, falling back to the global default."
  @spec get_default_adapter(binary() | atom(), binary() | nil) :: Ecto.Schema.t() | nil
  defdelegate get_default_adapter(channel, tenant_key), to: ChannelAdapters

  @doc "Creates an HTTP hook for a sequence."
  @spec create_http_hook(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_http_hook(sequence_id, attrs), to: HttpHooks

  @doc "Updates an HTTP hook."
  @spec update_http_hook(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_http_hook(hook, attrs), to: HttpHooks

  @doc "Runs an HTTP hook out of band and stores its redacted test result."
  @spec test_http_hook(Ecto.UUID.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate test_http_hook(hook_id, test_data), to: HttpHooks

  @doc "Deprecated unscoped HTTP hook listing. Use `list_http_hooks/2`."
  @spec list_http_hooks(Ecto.UUID.t()) :: no_return()
  defdelegate list_http_hooks(sequence_id), to: HttpHooks

  @doc "Lists HTTP hooks for a sequence and explicit tenant scope."
  @spec list_http_hooks(Ecto.UUID.t(), binary() | nil) :: [Ecto.Schema.t()]
  defdelegate list_http_hooks(sequence_id, tenant_key), to: HttpHooks

  @doc "Creates or updates a suppression for a channel recipient."
  @spec suppress(map()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate suppress(attrs), to: Suppressions

  @doc "Enrolls a subscriber into the active version of a sequence."
  @spec enroll(map()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate enroll(attrs), to: Enrollments

  @doc "Deprecated unscoped cancel. Use `unenroll/2`."
  @spec unenroll(Ecto.UUID.t()) :: no_return()
  defdelegate unenroll(enrollment_id), to: Enrollments

  @doc "Cancels an enrollment scoped by tenant."
  @spec unenroll(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate unenroll(enrollment_id, tenant_key), to: Enrollments

  @doc "Deprecated unscoped pause. Use `pause_enrollment/2`."
  @spec pause_enrollment(Ecto.UUID.t()) :: no_return()
  defdelegate pause_enrollment(enrollment_id), to: Enrollments

  @doc "Pauses an enrollment scoped by tenant."
  @spec pause_enrollment(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate pause_enrollment(enrollment_id, tenant_key), to: Enrollments

  @doc "Deprecated unscoped resume. Use `resume_enrollment/2`."
  @spec resume_enrollment(Ecto.UUID.t()) :: no_return()
  defdelegate resume_enrollment(enrollment_id), to: Enrollments

  @doc "Resumes an enrollment scoped by tenant."
  @spec resume_enrollment(Ecto.UUID.t(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate resume_enrollment(enrollment_id, tenant_key), to: Enrollments

  @doc "Tracks an event by subscriber identity (tenant_key in the map) or deprecated unscoped enrollment id."
  @spec track_event(Ecto.UUID.t() | map(), binary(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()} | no_return()
  defdelegate track_event(identity, event_key, event_data), to: Enrollments

  @doc "Tracks an event for a tenant-scoped enrollment id."
  @spec track_event(Ecto.UUID.t(), binary(), map(), binary() | nil) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  defdelegate track_event(enrollment_id, event_key, event_data, tenant_key), to: Enrollments

  @doc "Lists active enrollments."
  @spec list_active_enrollments(map()) :: [Ecto.Schema.t()]
  defdelegate list_active_enrollments(filters \\ %{}), to: Enrollments

  @doc "Deprecated unscoped enrollment lookup. Use `get_enrollment/4`."
  @spec get_enrollment(Ecto.UUID.t(), binary(), binary()) :: no_return()
  defdelegate get_enrollment(sequence_id, subscriber_type, subscriber_id), to: Enrollments

  @doc "Gets an enrollment by sequence, subscriber identity, and explicit tenant scope."
  @spec get_enrollment(Ecto.UUID.t(), binary(), binary(), binary() | nil) :: Ecto.Schema.t() | nil
  defdelegate get_enrollment(sequence_id, subscriber_type, subscriber_id, tenant_key),
    to: Enrollments

  @doc "Replays a failed step execution with a fresh idempotency key."
  @spec replay(Ecto.UUID.t()) :: {:ok, Ecto.Schema.t()} | {:error, term()}
  defdelegate replay(step_execution_id), to: Dispatch

  @doc "Returns webhook routes declared by active channel adapters."
  @spec webhook_routes() :: [Channel.webhook_route()]
  defdelegate webhook_routes, to: Web
end
