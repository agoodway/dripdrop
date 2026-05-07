defmodule Mix.Tasks.Dripdrop.Uninstall do
  @moduledoc """
  Prints the SQL needed to remove DripDrop database objects.
  """

  @shortdoc "Prints SQL for uninstalling DripDrop"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} = OptionParser.parse(args, switches: [prefix: :string])
    prefix = Keyword.get(opts, :prefix, "dripdrop")

    Mix.shell().info("""
    -- Review carefully before running. This destroys all DripDrop data.
    DROP SCHEMA IF EXISTS "#{prefix}" CASCADE;
    """)
  end
end
