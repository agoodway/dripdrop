defmodule DripDrop.Fixtures do
  @moduledoc """
  Shared database fixtures for DripDrop tests.

  The helpers insert through schema changesets so tests exercise the same
  validations and constraints as host applications.
  """

  alias DripDrop.{
    AdapterPool,
    AdapterPoolMember,
    AdapterSequenceBudget,
    ChannelAdapter,
    Enrollment,
    HttpHook,
    MessageEvent,
    Sequence,
    SequenceVersion,
    Step,
    StepExecution,
    TestRepo
  }

  @doc """
  Inserts a sequence with a unique key.
  """
  @spec sequence_fixture(map()) :: Ecto.Schema.t()
  def sequence_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_key: "tenant-a",
          name: "Welcome sequence",
          key: unique_key("welcome"),
          metadata: %{}
        },
        attrs
      )

    %Sequence{}
    |> Sequence.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a sequence version for `sequence`.
  """
  @spec sequence_version_fixture(Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def sequence_version_fixture(%Sequence{} = sequence, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          sequence_id: sequence.id,
          tenant_key: sequence.tenant_key,
          version: 1,
          state: "draft",
          config: %{}
        },
        attrs
      )

    %SequenceVersion{}
    |> SequenceVersion.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a step for `version`.
  """
  @spec step_fixture(Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def step_fixture(%SequenceVersion{} = version, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          sequence_version_id: version.id,
          tenant_key: version.tenant_key,
          name: "Welcome email",
          key: unique_key("welcome-email"),
          position: 1,
          channel: "email",
          timing: %{type: "immediate"},
          template_type: "inline",
          template_content: %{"subject" => "Welcome", "body" => "Hello"},
          config: %{},
          active: true
        },
        attrs
      )

    %Step{}
    |> Step.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts an enrollment for `sequence` and `version`.
  """
  @spec enrollment_fixture(Ecto.Schema.t(), Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def enrollment_fixture(%Sequence{} = sequence, %SequenceVersion{} = version, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          sequence_id: sequence.id,
          sequence_version_id: version.id,
          tenant_key: sequence.tenant_key,
          subscriber_type: "user",
          subscriber_id: unique_key("subscriber"),
          state: "active",
          started_at: DateTime.utc_now(:second),
          data: %{},
          metadata: %{}
        },
        attrs
      )

    %Enrollment{}
    |> Enrollment.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a step execution for `enrollment` and `step`.
  """
  @spec step_execution_fixture(Ecto.Schema.t(), Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def step_execution_fixture(%Enrollment{} = enrollment, %Step{} = step, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          enrollment_id: enrollment.id,
          step_id: step.id,
          tenant_key: enrollment.tenant_key,
          state: "scheduled",
          scheduled_for: DateTime.utc_now(:second),
          idempotency_key: unique_key("idem"),
          channel: step.channel,
          recipient: "person@example.com",
          payload: %{},
          metadata: %{}
        },
        attrs
      )

    %StepExecution{}
    |> StepExecution.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a channel adapter.
  """
  @spec channel_adapter_fixture(map()) :: Ecto.Schema.t()
  def channel_adapter_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_key: "tenant-a",
          name: "Test SMTP",
          channel: "email",
          provider: "smtp",
          credentials: %{"relay" => "smtp.example.com"},
          config: %{},
          is_default: false,
          active: true
        },
        attrs
      )

    %ChannelAdapter{}
    |> ChannelAdapter.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts an adapter pool.
  """
  @spec adapter_pool_fixture(map()) :: Ecto.Schema.t()
  def adapter_pool_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_key: "tenant-a",
          name: unique_key("pool"),
          on_pin_unavailable: :pause,
          metadata: %{}
        },
        attrs
      )

    %AdapterPool{}
    |> AdapterPool.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts an adapter pool member.
  """
  @spec adapter_pool_member_fixture(Ecto.Schema.t(), Ecto.Schema.t(), map()) :: Ecto.Schema.t()
  def adapter_pool_member_fixture(
        %AdapterPool{} = pool,
        %ChannelAdapter{} = adapter,
        attrs \\ %{}
      ) do
    attrs =
      Map.merge(
        %{
          pool_id: pool.id,
          adapter_id: adapter.id,
          class: :mailbox,
          weight: 1,
          active: true
        },
        attrs
      )

    %AdapterPoolMember{}
    |> AdapterPoolMember.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts an adapter sequence budget.
  """
  @spec adapter_sequence_budget_fixture(Ecto.Schema.t(), Ecto.Schema.t(), map()) ::
          Ecto.Schema.t()
  def adapter_sequence_budget_fixture(
        %ChannelAdapter{} = adapter,
        %SequenceVersion{} = version,
        attrs \\ %{}
      ) do
    attrs =
      Map.merge(
        %{
          adapter_id: adapter.id,
          sequence_version_id: version.id,
          weight: 1,
          max_share_pct: 100
        },
        attrs
      )

    %AdapterSequenceBudget{}
    |> AdapterSequenceBudget.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts an HTTP hook for a sequence.
  """
  @spec http_hook_fixture(Ecto.UUID.t(), map()) :: Ecto.Schema.t()
  def http_hook_fixture(sequence_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          sequence_id: sequence_id,
          tenant_key: "tenant-a",
          name: "Eligibility hook",
          key: unique_key("eligibility"),
          method: "POST",
          url: "https://hooks.example.test/eligibility",
          timeout_ms: 1_000,
          retry_count: 0,
          auth_type: "none",
          headers: %{},
          response_type: "json",
          active: true
        },
        attrs
      )

    %HttpHook{}
    |> HttpHook.changeset(attrs)
    |> TestRepo.insert!()
  end

  @doc """
  Inserts a message event.
  """
  @spec message_event_fixture(map()) :: Ecto.Schema.t()
  def message_event_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_key: "tenant-a",
          channel: "email",
          provider: "test",
          event_type: "sent",
          event_data: %{},
          occurred_at: DateTime.utc_now(:second)
        },
        attrs
      )
      |> derive_adapter_id_from_event_data()

    %MessageEvent{}
    |> MessageEvent.changeset(attrs)
    |> TestRepo.insert!()
  end

  defp derive_adapter_id_from_event_data(%{adapter_id: id} = attrs) when not is_nil(id), do: attrs

  defp derive_adapter_id_from_event_data(attrs) do
    case get_in(attrs, [:event_data, "adapter_id"]) || get_in(attrs, [:event_data, :adapter_id]) do
      id when is_binary(id) -> Map.put(attrs, :adapter_id, id)
      _missing -> attrs
    end
  end

  defp unique_key(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
