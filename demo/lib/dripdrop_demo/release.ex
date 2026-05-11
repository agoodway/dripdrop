defmodule DripdropDemo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """

  alias DripDrop.Vault
  alias DripdropDemo.Application, as: DemoApplication

  @app :dripdrop_demo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          {:ok, _pid} = Vault.start_link()
          :ok = DemoApplication.register_demo_channels()
          load_seeds(repo)
        end)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp load_seeds(repo) do
    seed_file = Application.app_dir(@app, "priv/repo/seeds.exs")

    if File.exists?(seed_file) do
      Code.eval_file(seed_file)
      IO.puts("Seeds loaded for #{inspect(repo)}")
    else
      IO.puts("No seed file found at #{seed_file}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
