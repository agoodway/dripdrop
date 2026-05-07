defmodule DripDrop.Repo do
  @moduledoc """
  Thin delegating wrapper around the host-configured DripDrop repo.

  Library code calls this module so applications can provide their own Ecto
  repo through `config :dripdrop, :repo`.
  """

  @spec repo!() :: module()
  @doc """
  Returns the host-configured Ecto repo or raises when DripDrop is not configured.
  """
  def repo! do
    case Application.fetch_env!(:dripdrop, :repo) do
      nil -> raise "config :dripdrop, :repo is required"
      repo -> repo
    end
  end

  @spec insert(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Inserts a changeset through the configured repo.
  """
  def insert(changeset, opts \\ []), do: repo!().insert(changeset, opts)

  @spec update(Ecto.Changeset.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates a changeset through the configured repo.
  """
  def update(changeset, opts \\ []), do: repo!().update(changeset, opts)

  @spec get!(module(), term(), keyword()) :: Ecto.Schema.t()
  @doc """
  Fetches one schema row by primary key, raising when it is missing.
  """
  def get!(schema, id, opts \\ []), do: repo!().get!(schema, id, opts)

  @spec get(module(), term(), keyword()) :: Ecto.Schema.t() | nil
  @doc """
  Fetches one schema row by primary key, returning `nil` when it is missing.
  """
  def get(schema, id, opts \\ []), do: repo!().get(schema, id, opts)

  @spec all(Ecto.Queryable.t(), keyword()) :: [Ecto.Schema.t()]
  @doc """
  Runs a query and returns all rows.
  """
  def all(query, opts \\ []), do: repo!().all(query, opts)

  @spec one(Ecto.Queryable.t(), keyword()) :: Ecto.Schema.t() | nil
  @doc """
  Runs a query expected to return zero or one row.
  """
  def one(query, opts \\ []), do: repo!().one(query, opts)

  @spec update_all(Ecto.Queryable.t(), keyword(), keyword()) ::
          {non_neg_integer(), nil | [term()]}
  @doc """
  Runs an `update_all` through the configured repo.
  """
  def update_all(query, updates, opts \\ []), do: repo!().update_all(query, updates, opts)

  @spec query(String.t(), list(), keyword()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  @doc """
  Executes raw SQL through the configured repo.
  """
  def query(sql, params \\ [], opts \\ []), do: repo!().query(sql, params, opts)

  @spec transaction(Ecto.Multi.t(), keyword()) :: {:ok, map()} | {:error, atom(), term(), map()}
  @doc """
  Runs an `Ecto.Multi` transaction through the configured repo.
  """
  def transaction(multi, opts \\ []), do: repo!().transaction(multi, opts)
end
