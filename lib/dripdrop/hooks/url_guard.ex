defmodule DripDrop.Hooks.URLGuard do
  @moduledoc """
  Validates outbound HTTP hook URLs to mitigate SSRF.

  The guard enforces a scheme allowlist (https by default; http opt-in via
  `config :dripdrop, :http_hook_allow_http, true`), resolves the host to its
  IP addresses, and rejects any address inside a private, loopback, link-local,
  CGNAT, or unique-local range unless
  `config :dripdrop, :http_hook_allow_private, true` is set. Validation runs
  both at `HttpHook` create/update time and again after Liquid rendering inside
  the evaluator, since template variables can rewrite the host.
  """

  import Bitwise, only: [&&&: 2, |||: 2, <<<: 2]

  @blocked_ipv4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4},
    {{255, 255, 255, 255}, 32}
  ]

  @blocked_ipv6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Returns `:ok` if `url` is safe to fetch, otherwise `{:error, reason}`.

  Pass `req_options:` (a keyword list of Req options) to opt out when the
  caller is using `Req.Test` stubbing — that bypasses real DNS so the guard
  can't resolve example fixtures.
  """
  @spec validate(binary() | nil, keyword()) :: :ok | {:error, atom()}
  def validate(url, opts \\ [])

  def validate(url, opts) when is_binary(url) do
    if req_test_stubbed?(opts) do
      :ok
    else
      with {:ok, uri} <- parse(url),
           :ok <- validate_scheme(uri) do
        validate_host(uri.host)
      end
    end
  end

  def validate(_url, _opts), do: {:error, :invalid_url}

  defp req_test_stubbed?(opts) do
    case Keyword.get(opts, :req_options, []) do
      req_opts when is_list(req_opts) ->
        match?({Req.Test, _name}, Keyword.get(req_opts, :plug))

      _other ->
        false
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp validate_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_scheme(%URI{scheme: "http"}) do
    if Application.get_env(:dripdrop, :http_hook_allow_http, false) do
      :ok
    else
      {:error, :scheme_not_allowed}
    end
  end

  defp validate_scheme(_uri), do: {:error, :scheme_not_allowed}

  defp validate_host(nil), do: {:error, :invalid_host}
  defp validate_host(""), do: {:error, :invalid_host}

  defp validate_host(host) do
    with {:ok, addrs} <- resolve_addrs(host) do
      if not Application.get_env(:dripdrop, :http_hook_allow_private, false) and
           Enum.any?(addrs, &blocked_ip?/1),
         do: {:error, :private_address},
         else: :ok
    end
  end

  defp resolve_addrs(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, addr} ->
        {:ok, [addr]}

      {:error, :einval} ->
        with {:ok, ipv4} <- getaddrs(charlist, :inet),
             {:ok, ipv6} <- getaddrs_optional(charlist, :inet6) do
          {:ok, ipv4 ++ ipv6}
        end
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> {:ok, addrs}
      {:error, _reason} -> {:error, :host_unresolvable}
    end
  end

  defp getaddrs_optional(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> {:ok, addrs}
      {:error, _reason} -> {:ok, []}
    end
  end

  defp blocked_ip?({_a, _b, _c, _d} = ip) do
    Enum.any?(@blocked_ipv4, fn {network, prefix} -> in_subnet_v4?(ip, network, prefix) end)
  end

  defp blocked_ip?({_a, _b, _c, _d, _e, _f, _g, _h} = ip) do
    Enum.any?(@blocked_ipv6, fn {network, prefix} -> in_subnet_v6?(ip, network, prefix) end)
  end

  defp blocked_ip?(_other), do: true

  defp in_subnet_v4?(ip, network, prefix) do
    mask = mask_v4(prefix)
    (ipv4_to_int(ip) &&& mask) == (ipv4_to_int(network) &&& mask)
  end

  defp in_subnet_v6?(ip, network, prefix) do
    mask = mask_v6(prefix)
    (ipv6_to_int(ip) &&& mask) == (ipv6_to_int(network) &&& mask)
  end

  defp mask_v4(0), do: 0
  defp mask_v4(prefix) when prefix in 1..32, do: ((1 <<< prefix) - 1) <<< (32 - prefix)

  defp mask_v6(0), do: 0
  defp mask_v6(prefix) when prefix in 1..128, do: ((1 <<< prefix) - 1) <<< (128 - prefix)

  defp ipv4_to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp ipv6_to_int({a, b, c, d, e, f, g, h}) do
    a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 |||
      g <<< 16 ||| h
  end
end
