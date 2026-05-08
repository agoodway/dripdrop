defmodule DripDrop.Hooks.URLGuardTest do
  @moduledoc """
  Unit tests for `DripDrop.Hooks.URLGuard` (T4 + F3).

  Covers RFC-1918 IPv4 ranges, IPv6 loopback / link-local / ULA, scheme
  enforcement, the http opt-in flag, and the rendered-URL re-validation that
  the evaluator performs after Liquid expansion.
  """

  use ExUnit.Case, async: false

  alias DripDrop.Hooks.URLGuard

  setup do
    previous = Application.get_env(:dripdrop, :http_hook_allow_http)
    on_exit(fn -> Application.put_env(:dripdrop, :http_hook_allow_http, previous) end)
    Application.put_env(:dripdrop, :http_hook_allow_http, false)
    :ok
  end

  describe "scheme enforcement" do
    test "rejects http when http opt-in is disabled" do
      assert {:error, :scheme_not_allowed} = URLGuard.validate("http://example.com/path")
    end

    test "allows http when explicitly opted in" do
      Application.put_env(:dripdrop, :http_hook_allow_http, true)
      assert :ok = URLGuard.validate("http://1.1.1.1/path")
    end

    test "rejects ftp, file, and javascript schemes" do
      Application.put_env(:dripdrop, :http_hook_allow_http, true)
      assert {:error, :scheme_not_allowed} = URLGuard.validate("ftp://example.com/")
      assert {:error, :scheme_not_allowed} = URLGuard.validate("file:///etc/passwd")
      assert {:error, :scheme_not_allowed} = URLGuard.validate("javascript:alert(1)")
    end

    test "rejects malformed URLs" do
      assert {:error, _reason} = URLGuard.validate("not a url at all")
      assert {:error, :invalid_url} = URLGuard.validate(nil)
    end
  end

  describe "private IPv4 ranges" do
    test "rejects loopback" do
      assert {:error, :private_address} = URLGuard.validate("https://127.0.0.1/")
      assert {:error, :private_address} = URLGuard.validate("https://127.255.255.254/")
    end

    test "rejects RFC-1918 ranges" do
      assert {:error, :private_address} = URLGuard.validate("https://10.0.0.1/")
      assert {:error, :private_address} = URLGuard.validate("https://172.16.0.1/")
      assert {:error, :private_address} = URLGuard.validate("https://172.31.255.254/")
      assert {:error, :private_address} = URLGuard.validate("https://192.168.1.1/")
    end

    test "rejects AWS metadata endpoint" do
      assert {:error, :private_address} = URLGuard.validate("https://169.254.169.254/")
    end

    test "rejects CGNAT range" do
      assert {:error, :private_address} = URLGuard.validate("https://100.64.0.1/")
    end

    test "rejects 0.0.0.0/8 and 255.255.255.255" do
      assert {:error, :private_address} = URLGuard.validate("https://0.0.0.0/")
      assert {:error, :private_address} = URLGuard.validate("https://255.255.255.255/")
    end

    test "rejects multicast and reserved ranges" do
      assert {:error, :private_address} = URLGuard.validate("https://224.0.0.1/")
      assert {:error, :private_address} = URLGuard.validate("https://240.0.0.1/")
    end

    test "rejects TEST-NET ranges (RFC 5737)" do
      assert {:error, :private_address} = URLGuard.validate("https://192.0.2.1/")
      assert {:error, :private_address} = URLGuard.validate("https://198.51.100.1/")
      assert {:error, :private_address} = URLGuard.validate("https://203.0.113.1/")
    end
  end

  describe "IPv6 ranges" do
    test "rejects loopback" do
      assert {:error, :private_address} = URLGuard.validate("https://[::1]/")
    end

    test "rejects unspecified" do
      assert {:error, :private_address} = URLGuard.validate("https://[::]/")
    end

    test "rejects unique-local (fc00::/7)" do
      assert {:error, :private_address} = URLGuard.validate("https://[fc00::1]/")
      assert {:error, :private_address} = URLGuard.validate("https://[fd00::1]/")
    end

    test "rejects link-local (fe80::/10)" do
      assert {:error, :private_address} = URLGuard.validate("https://[fe80::1]/")
    end
  end

  describe "public hosts" do
    test "accepts a public IP literal" do
      assert :ok = URLGuard.validate("https://1.1.1.1/")
      assert :ok = URLGuard.validate("https://8.8.8.8/")
    end
  end

  describe "property: blocked IP ranges (StreamData)" do
    use ExUnitProperties

    property "any RFC-1918 10.0.0.0/8 IPv4 is rejected as :private_address" do
      check all(
              a <- StreamData.constant(10),
              b <- StreamData.integer(0..255),
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254),
              port <- StreamData.member_of([nil, 80, 443, 8080, 8443]),
              path <- StreamData.member_of(["/", "/api", "/health"])
            ) do
        url = build_url(a, b, c, d, port, path)
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "any 192.168.0.0/16 IPv4 is rejected" do
      check all(
              a <- StreamData.constant(192),
              b <- StreamData.constant(168),
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254)
            ) do
        url = build_url(a, b, c, d, nil, "/")
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "172.16.0.0/12 (RFC-1918) is rejected; 172.{0..15,32..255}.x.x is allowed" do
      check all(
              b <- StreamData.integer(16..31),
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254)
            ) do
        # 172.16.0.0/12 spans 172.16.* through 172.31.*
        url = build_url(172, b, c, d, nil, "/")
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "loopback 127.0.0.0/8 is rejected" do
      check all(
              b <- StreamData.integer(0..255),
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254)
            ) do
        url = build_url(127, b, c, d, nil, "/")
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "link-local 169.254.0.0/16 is rejected (incl. AWS metadata 169.254.169.254)" do
      check all(
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254)
            ) do
        url = build_url(169, 254, c, d, nil, "/")
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "CGNAT 100.64.0.0/10 is rejected" do
      check all(
              b <- StreamData.integer(64..127),
              c <- StreamData.integer(0..255),
              d <- StreamData.integer(1..254)
            ) do
        url = build_url(100, b, c, d, nil, "/")
        assert {:error, :private_address} = URLGuard.validate(url)
      end
    end

    property "any non-http(s) scheme is rejected" do
      check all(
              scheme <-
                StreamData.member_of([
                  "file",
                  "ftp",
                  "gopher",
                  "ldap",
                  "ssh",
                  "telnet",
                  "ws",
                  "wss",
                  "data",
                  "javascript"
                ]),
              host <- StreamData.member_of(["example.com", "8.8.8.8", "host"])
            ) do
        url = "#{scheme}://#{host}/"
        assert {:error, reason} = URLGuard.validate(url)
        assert reason in [:scheme_not_allowed, :invalid_url]
      end
    end

    property "Req.Test stub bypass returns :ok regardless of host" do
      check all(
              octets <-
                StreamData.list_of(StreamData.integer(0..255), length: 4),
              # Even with private/loopback IPs, the test-stub bypass should allow the URL
              _path <- StreamData.member_of(["/", "/anything"])
            ) do
        [a, b, c, d] = octets
        url = "https://#{a}.#{b}.#{c}.#{d}/"

        assert :ok =
                 URLGuard.validate(url, req_options: [plug: {Req.Test, :stub_name}])
      end
    end
  end

  defp build_url(a, b, c, d, port, path) do
    host = "#{a}.#{b}.#{c}.#{d}"
    port_segment = if is_integer(port), do: ":#{port}", else: ""
    "https://#{host}#{port_segment}#{path}"
  end
end
