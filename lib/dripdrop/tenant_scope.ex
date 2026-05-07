defmodule DripDrop.TenantScope do
  @moduledoc """
  Helpers for enforcing explicit tenant scope on query APIs.

  DripDrop allows global records with `tenant_key: nil`, but callers must be
  explicit when they intend that global scope. Omitting the key entirely is
  rejected so list/get helpers do not accidentally leak rows across tenants.
  """

  @doc """
  Fetches `tenant_key` from a filter map, raising when it is absent.
  """
  @spec fetch!(map(), atom()) :: binary() | nil
  def fetch!(%{tenant_key: value}, _context), do: value
  def fetch!(%{"tenant_key" => value}, _context), do: value

  def fetch!(filters, context) when is_map(filters) do
    raise ArgumentError, "#{context} requires an explicit :tenant_key"
  end

  @doc """
  Raises a consistent tenant-scope error for deprecated unscoped APIs.
  """
  @spec raise_missing!(atom()) :: no_return()
  def raise_missing!(context) do
    raise ArgumentError, "#{context} requires an explicit :tenant_key"
  end
end
