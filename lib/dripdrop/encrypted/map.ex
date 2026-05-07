defmodule DripDrop.Encrypted.Map do
  @moduledoc """
  Cloak Ecto type for maps encrypted with `DripDrop.Vault`.
  """

  alias DripDrop.Vault

  use Cloak.Ecto.Map, vault: Vault
end
