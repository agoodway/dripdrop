defmodule DripDrop.HttpHooks do
  @moduledoc """
  Context for HTTP hooks.
  """

  import Ecto.Query

  alias DripDrop.{Clock, HttpHook, Repo, Sequence, TenantScope}
  alias DripDrop.Hooks.Evaluator

  @spec create_http_hook(Ecto.UUID.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates an HTTP hook for a sequence.
  """
  def create_http_hook(sequence_id, attrs) when is_map(attrs) do
    sequence = Repo.repo!().get!(Sequence, sequence_id)

    attrs =
      attrs
      |> Map.put(:sequence_id, sequence_id)
      |> Map.put(:tenant_key, sequence.tenant_key)

    %HttpHook{}
    |> HttpHook.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_http_hook(Ecto.Schema.t(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates an HTTP hook.
  """
  def update_http_hook(%HttpHook{} = hook, attrs) when is_map(attrs) do
    hook
    |> HttpHook.changeset(attrs)
    |> Repo.update()
  end

  @spec list_http_hooks(Ecto.UUID.t()) :: no_return()
  @doc """
  Deprecated unscoped listing. Use `list_http_hooks/2` with an explicit tenant key.
  """
  def list_http_hooks(sequence_id) do
    _unused = sequence_id
    TenantScope.raise_missing!(:list_http_hooks)
  end

  @spec list_http_hooks(Ecto.UUID.t(), binary() | nil) :: [Ecto.Schema.t()]
  @doc """
  Lists HTTP hooks for a sequence and explicit tenant scope, ordered by key.
  """
  def list_http_hooks(sequence_id, tenant_key) do
    HttpHook
    |> where([hook], hook.sequence_id == ^sequence_id)
    |> where_tenant_scope(tenant_key)
    |> order_by([hook], asc: hook.key)
    |> Repo.all()
  end

  @spec test_http_hook(Ecto.UUID.t(), map()) :: {:ok, term()} | {:error, term()}
  @doc """
  Executes a hook with test data and stores the redacted test result.
  """
  def test_http_hook(hook_id, test_data) when is_map(test_data) do
    repo = Repo.repo!()
    hook = repo.get!(HttpHook, hook_id)
    result = Evaluator.run_http_hook(hook, test_data, cache?: false)

    hook
    |> HttpHook.changeset(%{
      last_test_at: Clock.now(),
      last_test_result: DripDrop.Redact.scrub(%{result: inspect(result)})
    })
    |> Repo.update()

    result
  end

  defp where_tenant_scope(query, nil), do: where(query, [hook], is_nil(hook.tenant_key))

  defp where_tenant_scope(query, tenant_key),
    do: where(query, [hook], hook.tenant_key == ^tenant_key)
end
