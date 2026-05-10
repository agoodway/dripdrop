defmodule DripDrop.Helpers do
  @moduledoc """
  Shared helpers for data shaping, module resolution, and small parsing tasks.

  Domain modules should use these helpers when the logic is generic enough to
  apply across dispatch, hooks, templates, and policies.
  """

  alias DripDrop.{Clock, Timing}

  @doc """
  Recursively converts map keys to strings.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  def stringify_keys(value), do: value

  @doc """
  Reads a dotted path from a map with string or existing-atom keys.
  """
  @spec get_path(term(), binary() | nil) :: term()
  def get_path(data, nil), do: data

  def get_path(data, path) do
    path
    |> String.trim_leading("$.")
    |> String.split(".", trim: true)
    |> Enum.reduce(data, fn key, acc ->
      if is_map(acc), do: Map.get(acc, key) || existing_atom_value(acc, key), else: nil
    end)
  end

  @doc """
  Resolves a module from an atom or existing Elixir module name.
  """
  @spec module_from_string(module() | binary() | nil, term(), term()) ::
          {:ok, module()} | {:error, term()}
  def module_from_string(module, missing_reason, unknown_reason \\ :unknown_module_or_function)
  def module_from_string(nil, missing_reason, _unknown_reason), do: {:error, missing_reason}

  def module_from_string(module, _missing_reason, _unknown_reason) when is_atom(module),
    do: {:ok, module}

  def module_from_string(module, _missing_reason, unknown_reason) when is_binary(module) do
    with {:ok, module} <- module_atom(module, unknown_reason),
         {:module, module} <- Code.ensure_loaded(module) do
      {:ok, module}
    else
      {:error, _reason} -> {:error, unknown_reason}
    end
  end

  @doc """
  Converts an atom or existing atom string into an atom.
  """
  @spec existing_atom(atom() | binary() | nil, term()) :: {:ok, atom()} | {:error, term()}
  def existing_atom(value, unknown_reason \\ :unknown_module_or_function)
  def existing_atom(nil, unknown_reason), do: {:error, unknown_reason}
  def existing_atom(value, _unknown_reason) when is_atom(value), do: {:ok, value}

  def existing_atom(value, unknown_reason) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, unknown_reason}
  end

  @doc """
  Returns the existing atom for a binary, falling back to the original binary
  when the atom is unknown. Used to normalize map keys from external input
  without growing the global atom table.
  """
  @spec atom_or_string(atom() | binary()) :: atom() | binary()
  def atom_or_string(value) when is_atom(value), do: value

  def atom_or_string(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  @doc """
  Fetches `key` from `map`, transparently accepting either a string or atom
  key. Looks up the literal key first; on miss, tries `atom_or_string/1` to
  resolve a matching atom key without growing the atom table. Returns
  `default` when neither shape is present.

  Use anywhere config / credential / payload maps may arrive with string OR
  atom keys, instead of writing `Map.get(map, key) || Map.get(map, String.to_atom(key))`
  (which is unsafe — `String.to_atom` grows the atom table).
  """
  @spec fetch_string_or_atom_key(map() | nil, atom() | binary(), term()) :: term()
  def fetch_string_or_atom_key(map, key, default \\ nil)
  def fetch_string_or_atom_key(nil, _key, default), do: default

  def fetch_string_or_atom_key(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, alternate_key(key), default)
    end
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)
  defp alternate_key(key) when is_binary(key), do: atom_or_string(key)
  defp alternate_key(key), do: key

  @doc """
  Normalizes a string key (trim, downcase, replace `-` with `_`). Atoms pass
  through unchanged. Returns `nil` for `nil`. Used for channel/provider keys
  and other slug-style identifiers.
  """
  @spec slugify_key(atom() | binary() | nil) :: atom() | binary() | nil
  def slugify_key(nil), do: nil
  def slugify_key(key) when is_atom(key), do: key

  def slugify_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  @doc """
  Atomizes string keys in a map using `String.to_existing_atom/1`. Falls back
  to returning the **original map unchanged** when *any* key is unknown — this
  preserves all-or-nothing semantics so callers downstream can rely on a
  single key shape (atom-only or string-only) rather than a mixed map.
  """
  @spec atomize_existing_keys_strict(map()) :: map()
  def atomize_existing_keys_strict(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  rescue
    ArgumentError -> map
  end

  @http_methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @http_method_atoms Map.values(@http_methods)

  @doc """
  Coerces an HTTP method into the lowercase atom Req and Plug expect.
  Raises when the value is not one of `GET / POST / PUT / PATCH / DELETE`.

  Use this for trusted input (e.g. enum-validated DB columns) where any
  failure represents a real invariant break.
  """
  @spec http_method!(atom() | binary()) :: :get | :post | :put | :patch | :delete
  def http_method!(method) when method in @http_method_atoms, do: method

  def http_method!(method) when is_binary(method) or is_atom(method) do
    Map.fetch!(@http_methods, method |> to_string() |> String.upcase())
  end

  @doc """
  Same as `http_method!/1`, but returns `default` for unknown input instead
  of raising. Use this for untrusted input (request payloads, user maps).
  """
  @spec http_method(atom() | binary() | nil, atom()) :: :get | :post | :put | :patch | :delete
  def http_method(method, default \\ :post)

  def http_method(method, _default) when method in @http_method_atoms, do: method

  def http_method(method, default) when is_binary(method) or is_atom(method) do
    Map.get(@http_methods, method |> to_string() |> String.upcase(), default)
  end

  def http_method(_method, default), do: default

  @doc """
  Extracts and lowercases the first email address in a value.
  """
  @spec email_address(term()) :: binary() | nil
  def email_address(nil), do: nil

  def email_address(value) do
    value
    |> to_string()
    |> then(&Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, &1))
    |> case do
      [email] -> String.downcase(email)
      _invalid -> nil
    end
  end

  @doc """
  Extracts and lowercases the domain of the first email address in a value.
  """
  @spec email_domain(term()) :: binary() | nil
  def email_domain(nil), do: nil

  def email_domain(value) do
    value
    |> to_string()
    |> then(&Regex.run(~r/[A-Z0-9._%+\-]+@([A-Z0-9.\-]+\.[A-Z]{2,})/i, &1))
    |> case do
      [_email, domain] -> String.downcase(domain)
      _invalid -> nil
    end
  end

  @doc """
  Extracts the recipient domain from a value. Accepts either a payload-like
  map with `to`/`recipient` keys (string or atom) or a plain email-like
  string. Returns the lowercased domain part, or `nil` when no email-shaped
  value is present.

  Mirrors the sender-side extraction (`email_domain/1` invoked against a
  `from`/`reply_to` field) for the recipient side, used by the
  per-recipient-domain rate-limit scope to bucket sends by recipient ISP.
  """
  @spec recipient_domain(term()) :: binary() | nil
  def recipient_domain(nil), do: nil

  def recipient_domain(value) when is_map(value) do
    value
    |> recipient_address()
    |> email_domain()
  end

  def recipient_domain(value), do: email_domain(value)

  defp recipient_address(payload) do
    Map.get(payload, :to) ||
      Map.get(payload, "to") ||
      Map.get(payload, :recipient) ||
      Map.get(payload, "recipient")
  end

  @doc """
  Calculates the next scheduled timestamp for a timing struct.
  """
  @spec scheduled_for(Ecto.Schema.t()) :: DateTime.t()
  def scheduled_for(timing) do
    case Timing.calculate_next_run(timing, DateTime.utc_now()) do
      {:ok, %DateTime{} = datetime} -> DateTime.truncate(datetime, :second)
      _error -> Clock.now()
    end
  end

  defp existing_atom_value(map, key) do
    key
    |> String.to_existing_atom()
    |> then(&Map.get(map, &1))
  rescue
    ArgumentError -> nil
  end

  defp module_atom(module, unknown_reason) do
    module =
      module
      |> String.trim()
      |> String.trim_leading("Elixir.")

    if valid_module_name?(module) do
      {:ok, module |> String.split(".") |> Module.safe_concat()}
    else
      {:error, unknown_reason}
    end
  rescue
    ArgumentError -> {:error, unknown_reason}
  end

  defp valid_module_name?(module) do
    Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, module)
  end
end
