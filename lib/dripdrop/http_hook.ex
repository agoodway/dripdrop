defmodule DripDrop.HttpHook do
  @moduledoc """
  Stores an HTTP hook that sequence conditions can call during dispatch.

  Hooks are scoped to a sequence, render their URL/body with template variables,
  and optionally extract a typed value from the response.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias DripDrop.Encrypted
  alias DripDrop.Sequence

  @primary_key {:id, :binary_id, autogenerate: false, read_after_writes: true}
  @foreign_key_type :binary_id
  @schema_prefix "dripdrop"
  @methods ~w(GET POST PUT PATCH DELETE)
  @auth_types ~w(none bearer basic header)
  @response_types ~w(json text number boolean)

  @derive {Inspect, except: [:auth_config]}
  schema "http_hooks" do
    field(:tenant_key, :string)
    field(:name, :string)
    field(:key, :string)
    field(:description, :string)
    field(:method, :string, default: "POST")
    field(:url, :string)
    field(:timeout_ms, :integer, default: 5_000)
    field(:retry_count, :integer, default: 2)
    field(:auth_type, :string, default: "none")
    field(:auth_config, Encrypted.Map)
    field(:headers, :map, default: %{})
    field(:body_template, :string)
    field(:response_path, :string)
    field(:response_type, :string, default: "json")
    field(:active, :boolean, default: true)
    field(:last_test_at, :utc_datetime)
    field(:last_test_result, :map)

    belongs_to(:sequence, Sequence)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating an HTTP hook.
  """
  @spec changeset(Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [
      :sequence_id,
      :tenant_key,
      :name,
      :key,
      :description,
      :method,
      :url,
      :timeout_ms,
      :retry_count,
      :auth_type,
      :auth_config,
      :headers,
      :body_template,
      :response_path,
      :response_type,
      :active,
      :last_test_at,
      :last_test_result
    ])
    |> validate_required([:sequence_id, :name, :key, :method, :url, :timeout_ms, :retry_count])
    |> update_change(:key, &normalize_key/1)
    |> update_change(:method, &String.upcase/1)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> validate_inclusion(:method, @methods)
    |> validate_inclusion(:auth_type, @auth_types)
    |> validate_inclusion(:response_type, @response_types)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 30_000)
    |> validate_number(:retry_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_url_safe(:url)
    |> unique_constraint(:key, name: :http_hooks_sequence_key_idx)
    |> foreign_key_constraint(:sequence_id)
    |> check_constraint(:timeout_ms, name: :http_hooks_timeout_ms_range)
    |> check_constraint(:retry_count, name: :http_hooks_retry_count_range)
  end

  # The changeset validates scheme + URL syntax only. The actual DNS lookup
  # against private/loopback/link-local ranges happens in
  # `DripDrop.Hooks.URLGuard.validate/1` after Liquid render, since template
  # variables can rewrite the host and DNS resolution is TOCTOU-vulnerable
  # anyway. Render-time guard is the load-bearing protection.
  defp validate_url_safe(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, value} ->
        case validate_url_shape(value) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, field, message)
        end

      :error ->
        changeset
    end
  end

  defp validate_url_shape("https://" <> _rest), do: :ok
  defp validate_url_shape("http://" <> _rest), do: validate_http_allowed()
  defp validate_url_shape(value) when is_binary(value), do: {:error, "scheme must be https"}
  defp validate_url_shape(_value), do: {:error, "is not a valid URL"}

  defp validate_http_allowed do
    if Application.get_env(:dripdrop, :http_hook_allow_http, false),
      do: :ok,
      else: {:error, "scheme must be https"}
  end

  defp normalize_key(nil), do: nil

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
  end
end
