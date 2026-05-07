defmodule DripDrop.ShortLinks.None do
  @moduledoc """
  Short-link adapter that leaves destination URLs unchanged.
  """

  @behaviour DripDrop.ShortLinks.Adapter

  alias DripDrop.ShortLinks.Result

  @impl DripDrop.ShortLinks.Adapter
  def create_link(request, _opts) do
    {:ok, %Result{short_url: request.destination_url, response: %{skipped: true}}}
  end
end
