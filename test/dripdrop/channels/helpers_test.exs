defmodule DripDrop.Channels.HelpersTest do
  use ExUnit.Case, async: true

  alias DripDrop.Channels.Helpers

  describe "secure_compare/2" do
    test "returns true for equal binaries" do
      assert Helpers.secure_compare("abc", "abc")
    end

    test "returns false for unequal binaries of equal length" do
      refute Helpers.secure_compare("abc", "abd")
    end

    test "returns false for binaries of different length" do
      refute Helpers.secure_compare("abc", "abcd")
      refute Helpers.secure_compare("a", "")
    end

    test "returns false for non-binary input without raising" do
      refute Helpers.secure_compare(nil, "abc")
      refute Helpers.secure_compare("abc", nil)
      refute Helpers.secure_compare(:atom, "abc")
      refute Helpers.secure_compare(123, 123)
    end
  end

  describe "hmac_sha256_verify/3" do
    setup do
      key = "test-secret"
      payload = "timestamp=12345&token=abc"

      signature =
        :crypto.mac(:hmac, :sha256, key, payload) |> Base.encode16(case: :lower)

      {:ok, key: key, payload: payload, signature: signature}
    end

    test "verifies a valid HMAC-SHA256 signature", %{
      key: key,
      payload: payload,
      signature: signature
    } do
      assert Helpers.hmac_sha256_verify(key, payload, signature)
    end

    test "accepts uppercase hex signatures (case-insensitive)", %{
      key: key,
      payload: payload,
      signature: signature
    } do
      assert Helpers.hmac_sha256_verify(key, payload, String.upcase(signature))
    end

    test "rejects a tampered signature", %{key: key, payload: payload} do
      refute Helpers.hmac_sha256_verify(key, payload, String.duplicate("0", 64))
    end

    test "rejects a wrong-key signature", %{payload: payload, signature: signature} do
      refute Helpers.hmac_sha256_verify("wrong-key", payload, signature)
    end

    test "rejects a tampered payload", %{key: key, signature: signature} do
      refute Helpers.hmac_sha256_verify(key, "different payload", signature)
    end

    test "returns false for non-binary inputs" do
      refute Helpers.hmac_sha256_verify(nil, "x", "abc")
      refute Helpers.hmac_sha256_verify("k", "x", nil)
    end
  end

  describe "within_skew?/3" do
    test "accepts a current Unix timestamp (integer)" do
      now_unix = DateTime.utc_now() |> DateTime.to_unix()
      assert Helpers.within_skew?(now_unix, 300)
    end

    test "accepts a current Unix timestamp (string)" do
      now_unix = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
      assert Helpers.within_skew?(now_unix, 300)
    end

    test "accepts a current ISO 8601 timestamp" do
      iso = DateTime.utc_now() |> DateTime.to_iso8601()
      assert Helpers.within_skew?(iso, 300)
    end

    test "rejects timestamps outside the skew window" do
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix()
      refute Helpers.within_skew?(stale, 300)

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      refute Helpers.within_skew?(future, 300)
    end

    test "is symmetric — past and future skew rejected equally" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -301, :second) |> DateTime.to_unix()
      future = DateTime.add(now, 301, :second) |> DateTime.to_unix()

      refute Helpers.within_skew?(past, 300, now)
      refute Helpers.within_skew?(future, 300, now)
    end

    test "an explicit reference DateTime overrides clock-now" do
      reference = ~U[2026-05-07 12:00:00Z]
      ts = DateTime.add(reference, 60, :second) |> DateTime.to_unix()

      assert Helpers.within_skew?(ts, 300, reference)
      refute Helpers.within_skew?(ts, 30, reference)
    end

    test "returns false for unparseable input" do
      refute Helpers.within_skew?("not-a-timestamp", 300)
      refute Helpers.within_skew?(nil, 300)
      refute Helpers.within_skew?(:atom, 300)
    end
  end

  describe "credential/3" do
    test "reads with atom keys from a credentials map" do
      adapter = %{credentials: %{api_key: "secret"}}
      assert Helpers.credential(adapter, :api_key) == "secret"
    end

    test "falls back to string keys" do
      adapter = %{credentials: %{"api_key" => "secret"}}
      assert Helpers.credential(adapter, :api_key) == "secret"
    end

    test "returns the default when missing" do
      adapter = %{credentials: %{}}
      assert Helpers.credential(adapter, :api_key, "fallback") == "fallback"
    end

    test "accepts a bare credentials map (not wrapped in adapter)" do
      assert Helpers.credential(%{api_key: "x"}, :api_key) == "x"
    end
  end
end
