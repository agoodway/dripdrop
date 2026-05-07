defmodule Mix.Tasks.Dripdrop.CheckSchema do
  @moduledoc """
  Verifies that the configured database has the current DripDrop schema version.
  """

  @shortdoc "Verifies the installed dripdrop schema version"

  use Mix.Task

  alias DripDrop.MixHelpers

  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} =
      OptionParser.parse(args, switches: [repo: :string, prefix: :string])

    Mix.Task.run("app.config")

    repo = MixHelpers.resolve_repo(opts[:repo])
    prefix = Keyword.get(opts, :prefix, "dripdrop")

    {:ok, _started} = repo.start_link(pool_size: 2)

    installed = installed_version(repo, prefix)
    current = DripDrop.Migration.current_version()

    if installed == current do
      Mix.shell().info("dripdrop schema is current at version #{current}")
    else
      Mix.raise("dripdrop schema version mismatch: installed=#{installed}, expected=#{current}")
    end
  end

  defp installed_version(repo, prefix) do
    query = """
    SELECT obj_description(c.oid)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = 'dripdrop_version' AND c.relkind = 'v'
    """

    case repo.query(query, [prefix]) do
      {:ok, %{rows: [[comment]]}} when is_binary(comment) ->
        case Regex.run(~r/version=(\d+)/, comment) do
          [_, version] -> String.to_integer(version)
          _match -> 0
        end

      _other ->
        0
    end
  end
end
