defmodule DripDrop.MixHelpers do
  @moduledoc """
  Shared helpers for DripDrop Mix tasks.
  """

  @doc """
  Resolves the Ecto repo supplied to a Mix task or configured for the app.
  """
  @spec resolve_repo(String.t() | nil) :: module()
  def resolve_repo(nil) do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> Mix.raise("No Ecto repos configured. Add `:ecto_repos` to your app config.")
    end
  end

  def resolve_repo(repo_string), do: Module.concat([repo_string])

  @doc """
  Returns the repo priv path, defaulting to `priv/repo`.
  """
  @spec priv_path(module()) :: String.t()
  def priv_path(repo) do
    case repo.config()[:priv] do
      nil -> "priv/repo"
      priv when is_binary(priv) -> priv
    end
  rescue
    _error -> "priv/repo"
  end

  @doc """
  Returns the migrations directory for a repo.
  """
  @spec migrations_dir(module()) :: String.t()
  def migrations_dir(repo), do: Path.join(priv_path(repo), "migrations")

  @doc """
  Returns a UTC migration timestamp.
  """
  @spec timestamp() :: String.t()
  def timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  @doc """
  Checks whether a DripDrop setup migration already exists.
  """
  @spec setup_migration_exists?(String.t()) :: boolean()
  def setup_migration_exists?(migrations_dir) do
    migrations_dir
    |> Path.join("*_setup_dripdrop.exs")
    |> Path.wildcard()
    |> Enum.any?()
  end
end
