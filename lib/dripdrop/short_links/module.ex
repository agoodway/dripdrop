defmodule DripDrop.ShortLinks.Module do
  @moduledoc """
  Delegates short-link creation to a host-provided Elixir module.
  """

  @behaviour DripDrop.ShortLinks.Adapter

  @impl DripDrop.ShortLinks.Adapter
  def create_link(request, opts) do
    module = Keyword.fetch!(opts, :module)
    function = Keyword.get(opts, :function, :create_link)

    apply(module, function, [request, opts])
  end
end
