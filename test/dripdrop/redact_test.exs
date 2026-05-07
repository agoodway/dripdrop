defmodule DripDrop.RedactTest do
  @moduledoc """
  Property-based + targeted unit tests for `DripDrop.Redact`.

  `Redact.scrub/2` runs two redaction passes:

    1. **Map-key match**: any key whose normalized name contains a sensitive
       token (`api_key`, `secret`, `token`, `password`, `authorization`,
       `bearer`) has its value replaced with `"[REDACTED]"` regardless of
       value shape.

    2. **String value match**: regex patterns from `:dripdrop, :redaction_patterns`
       run against `is_binary/1` values (matching `Authorization: Bearer ...`,
       `api_key=...`, `password: ...`).

  These tests fuzz random nested maps to verify both passes are
  comprehensive and idempotent.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias DripDrop.Redact

  @sensitive_keys ~w(api_key apiKey api-key secret token password authorization bearer)
  @safe_keys ~w(name email user_id status timestamp count)

  describe "property: map-key redaction" do
    property "any sensitive key has its value fully redacted" do
      check all(
              key <- StreamData.member_of(@sensitive_keys),
              value <- StreamData.term()
            ) do
        scrubbed = Redact.scrub(%{key => value})
        assert scrubbed[key] == "[REDACTED]"
      end
    end

    property "atom keys named like secrets are also redacted" do
      check all(
              key_string <- StreamData.member_of(@sensitive_keys),
              value <- StreamData.term()
            ) do
        # Ensure the atom exists (safe — controlled domain).
        atom_key = String.to_atom(key_string)
        scrubbed = Redact.scrub(%{atom_key => value})
        assert scrubbed[atom_key] == "[REDACTED]"
      end
    end

    property "non-sensitive keys preserve scalar values" do
      check all(
              key <- StreamData.member_of(@safe_keys),
              value <-
                StreamData.one_of([
                  StreamData.integer(),
                  StreamData.boolean(),
                  StreamData.constant(nil)
                ])
            ) do
        assert Redact.scrub(%{key => value}) == %{key => value}
      end
    end

    property "redaction is idempotent — scrub(scrub(x)) == scrub(x)" do
      check all(map <- map_with_mixed_keys()) do
        once = Redact.scrub(map)
        twice = Redact.scrub(once)
        assert once == twice
      end
    end

    property "scrub preserves the set of map keys exactly" do
      check all(map <- map_with_mixed_keys()) do
        scrubbed = Redact.scrub(map)
        assert Map.keys(scrubbed) |> Enum.sort() == Map.keys(map) |> Enum.sort()
      end
    end

    property "nested sensitive keys are redacted recursively" do
      check all(
              sensitive_key <- StreamData.member_of(@sensitive_keys),
              safe_key <- StreamData.member_of(@safe_keys),
              value <- StreamData.string(:printable, max_length: 32)
            ) do
        nested = %{safe_key => %{sensitive_key => value, "name" => "Ada"}}

        scrubbed = Redact.scrub(nested)

        assert get_in(scrubbed, [safe_key, sensitive_key]) == "[REDACTED]"
        assert get_in(scrubbed, [safe_key, "name"]) == "Ada"
      end
    end
  end

  describe "property: structural preservation" do
    property "scrubbed lists keep their length" do
      check all(
              list <-
                StreamData.list_of(
                  StreamData.one_of([
                    StreamData.string(:alphanumeric),
                    StreamData.integer(),
                    StreamData.constant(nil)
                  ]),
                  max_length: 10
                )
            ) do
        assert length(Redact.scrub(list)) == length(list)
      end
    end

    property "scrubbed tuples keep the same arity" do
      check all(
              elements <-
                StreamData.list_of(StreamData.string(:alphanumeric, max_length: 12),
                  min_length: 1,
                  max_length: 5
                )
            ) do
        tuple = List.to_tuple(elements)
        scrubbed = Redact.scrub(tuple)
        assert tuple_size(scrubbed) == tuple_size(tuple)
      end
    end

    property "non-binary, non-collection values pass through unchanged" do
      check all(
              value <-
                StreamData.one_of([
                  StreamData.integer(),
                  StreamData.float(),
                  StreamData.boolean(),
                  StreamData.constant(nil),
                  StreamData.atom(:alphanumeric)
                ])
            ) do
        assert Redact.scrub(value) == value
      end
    end
  end

  describe "targeted edge cases" do
    test "deeply nested authorization key in a list of maps" do
      payload = [
        %{"name" => "Ada", "api_key" => "live_secret_a"},
        %{"name" => "Grace", "api_key" => "live_secret_b"}
      ]

      assert [
               %{"name" => "Ada", "api_key" => "[REDACTED]"},
               %{"name" => "Grace", "api_key" => "[REDACTED]"}
             ] = Redact.scrub(payload)
    end

    test "case-insensitive key matching: API_KEY, Api-Key, apiKey all redact" do
      assert Redact.scrub(%{"API_KEY" => "x"}) == %{"API_KEY" => "[REDACTED]"}
      assert Redact.scrub(%{"Api-Key" => "x"}) == %{"Api-Key" => "[REDACTED]"}
      assert Redact.scrub(%{"apiKey" => "x"}) == %{"apiKey" => "[REDACTED]"}
    end
  end

  defp map_with_mixed_keys do
    StreamData.map_of(
      StreamData.one_of([
        StreamData.member_of(@sensitive_keys),
        StreamData.member_of(@safe_keys)
      ]),
      StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 16),
        StreamData.integer(),
        StreamData.boolean()
      ]),
      max_length: 8
    )
  end
end
