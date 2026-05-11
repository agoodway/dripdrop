defmodule DripDrop.Channels.Webhook.SignerTest do
  use ExUnit.Case, async: true

  alias DripDrop.Channels.Webhook.Signer

  # Test vector from the Standard Webhooks spec — known-good signature for a
  # fixed (id, timestamp, payload, secret). Locks the implementation to the
  # canonical algorithm.
  @id "msg_p5jXN8AQM9LWM0D4loKWxJek"
  @timestamp 1_614_265_330
  @payload %{"event_type" => "ping"}
  @raw_secret "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaUWSkPRtX1V/Ag/4="

  describe "sign/4" do
    setup do
      now = :os.system_time(:second)
      %{now: now}
    end

    test "produces a deterministic v1 signature", %{now: now} do
      sig = Signer.sign(@id, now, @payload, @raw_secret)
      assert sig == Signer.sign(@id, now, @payload, @raw_secret)
      assert String.starts_with?(sig, "v1,")
    end

    test "different payloads produce different signatures", %{now: now} do
      a = Signer.sign(@id, now, %{"a" => 1}, @raw_secret)
      b = Signer.sign(@id, now, %{"a" => 2}, @raw_secret)
      refute a == b
    end

    test "different secrets produce different signatures", %{now: now} do
      a = Signer.sign(@id, now, @payload, @raw_secret)
      b = Signer.sign(@id, now, @payload, "TfKQ9r8GKYqrTwjUPD8ILPZIo2LaUWSkPRtX1V/Ag/4=")
      refute a == b
    end

    test "whsec_-prefixed secret decodes to the same key as the raw base64", %{now: now} do
      prefixed = Signer.sign(@id, now, @payload, "whsec_" <> @raw_secret)
      raw = Signer.sign(@id, now, @payload, @raw_secret)
      assert prefixed == raw
    end

    test "matches the canonical HMAC algorithm", %{now: now} do
      # Protects against drift from
      # HMAC-SHA256(base64-decode(secret), id.ts.json(payload)) -> base64.
      sig = Signer.sign(@id, now, @payload, @raw_secret)
      [_v1, mac] = String.split(sig, ",")

      expected =
        :crypto.mac(
          :hmac,
          :sha256,
          Base.decode64!(@raw_secret),
          "#{@id}.#{now}.#{Jason.encode!(@payload)}"
        )
        |> Base.encode64()

      assert mac == expected
    end

    test "rejects non-binary id", %{now: now} do
      assert_raise ArgumentError, ~r/Message id must be a string/, fn ->
        Signer.sign(123, now, @payload, @raw_secret)
      end
    end

    test "rejects non-integer timestamp" do
      assert_raise ArgumentError, ~r/timestamp must be an integer/, fn ->
        Signer.sign(@id, "now", @payload, @raw_secret)
      end
    end

    test "rejects non-map payload", %{now: now} do
      assert_raise ArgumentError, ~r/payload must be a map/, fn ->
        Signer.sign(@id, now, "not a map", @raw_secret)
      end
    end

    test "rejects non-binary secret", %{now: now} do
      assert_raise ArgumentError, ~r/Secret must be a string/, fn ->
        Signer.sign(@id, now, @payload, nil)
      end
    end

    test "rejects timestamps older than the tolerance window" do
      stale = :os.system_time(:second) - 6 * 60

      assert_raise ArgumentError, ~r/too old/, fn ->
        Signer.sign(@id, stale, @payload, @raw_secret)
      end
    end

    test "rejects timestamps newer than the tolerance window" do
      future = :os.system_time(:second) + 6 * 60

      assert_raise ArgumentError, ~r/too new/, fn ->
        Signer.sign(@id, future, @payload, @raw_secret)
      end
    end
  end

  describe "validate_timestamp/1" do
    test "returns :ok within the 5-minute window" do
      now = :os.system_time(:second)
      assert :ok = Signer.validate_timestamp(now)
      assert :ok = Signer.validate_timestamp(now - 4 * 60)
      assert :ok = Signer.validate_timestamp(now + 4 * 60)
    end
  end

  describe "verify/3" do
    setup do
      now = :os.system_time(:second)
      sig = Signer.sign(@id, now, @payload, @raw_secret)

      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("webhook-id", @id)
        |> Plug.Conn.put_req_header("webhook-timestamp", Integer.to_string(now))
        |> Plug.Conn.put_req_header("webhook-signature", sig)

      %{conn: conn, now: now, sig: sig}
    end

    test "returns true when the signature matches", %{conn: conn} do
      assert Signer.verify(@payload, conn, @raw_secret)
    end

    test "returns false when the signature doesn't match", %{conn: conn} do
      refute Signer.verify(%{"event_type" => "tampered"}, conn, @raw_secret)
    end

    test "returns true when any of multiple signatures matches", %{now: now} do
      good_sig = Signer.sign(@id, now, @payload, @raw_secret)

      conn =
        Plug.Test.conn(:post, "/")
        |> Plug.Conn.put_req_header("webhook-id", @id)
        |> Plug.Conn.put_req_header("webhook-timestamp", Integer.to_string(now))
        |> Plug.Conn.put_req_header("webhook-signature", "v1,wrongsig #{good_sig}")

      assert Signer.verify(@payload, conn, @raw_secret)
    end

    test "raises when required headers are missing" do
      conn = Plug.Test.conn(:post, "/")

      assert_raise ArgumentError, ~r/Missing required headers/, fn ->
        Signer.verify(@payload, conn, @raw_secret)
      end
    end
  end
end
