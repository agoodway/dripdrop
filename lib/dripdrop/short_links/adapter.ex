defmodule DripDrop.ShortLinks.Adapter do
  @moduledoc """
  Behaviour implemented by short-link providers.
  """

  alias DripDrop.ShortLinks.{Request, Result}

  @type error_kind :: :temporary | :permanent
  @type error :: %{kind: error_kind(), reason: term()}

  @callback create_link(Request.t(), keyword()) :: {:ok, Result.t()} | {:error, error()}
end
