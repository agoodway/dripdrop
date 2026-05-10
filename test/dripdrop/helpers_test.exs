defmodule DripDrop.HelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DripDrop.Helpers

  describe "module_from_string/3" do
    test "loads a configured module name" do
      assert Helpers.module_from_string("Elixir.DripDrop.Helpers", :missing) ==
               {:ok, DripDrop.Helpers}

      assert Helpers.module_from_string("DripDrop.Helpers", :missing) == {:ok, DripDrop.Helpers}
    end

    test "rejects invalid or unavailable module names" do
      assert Helpers.module_from_string(nil, :missing) == {:error, :missing}

      assert Helpers.module_from_string("not a module", :missing, :unknown) ==
               {:error, :unknown}

      assert Helpers.module_from_string("DripDrop.NoSuchModule", :missing, :unknown) ==
               {:error, :unknown}
    end
  end

  describe "atom_or_string/1" do
    test "returns existing atoms unchanged" do
      assert Helpers.atom_or_string(:foo) == :foo
    end

    test "converts known binaries to existing atoms" do
      _ensure = :existing_atom_for_test
      assert Helpers.atom_or_string("existing_atom_for_test") == :existing_atom_for_test
    end

    test "returns the binary when the atom is unknown" do
      random = "definitely_not_a_known_atom_#{System.unique_integer([:positive])}"
      assert Helpers.atom_or_string(random) == random
    end
  end

  describe "http_method!/1" do
    test "passes through known atoms" do
      for method <- [:get, :post, :put, :patch, :delete] do
        assert Helpers.http_method!(method) == method
      end
    end

    test "uppercases binaries to atoms" do
      assert Helpers.http_method!("GET") == :get
      assert Helpers.http_method!("post") == :post
      assert Helpers.http_method!("Patch") == :patch
    end

    test "raises on unknown methods" do
      assert_raise KeyError, fn -> Helpers.http_method!("BREW") end
      assert_raise KeyError, fn -> Helpers.http_method!(:options) end
    end

    test "raises on non-string non-atom input" do
      assert_raise FunctionClauseError, fn -> Helpers.http_method!(123) end
    end
  end

  describe "http_method/2" do
    test "returns the canonical atom for valid input" do
      assert Helpers.http_method("POST") == :post
      assert Helpers.http_method(:get) == :get
    end

    test "falls back to the default for unknown input" do
      assert Helpers.http_method("BREW") == :post
      assert Helpers.http_method(:options, :get) == :get
    end

    test "falls back when the input is nil or wrong type" do
      assert Helpers.http_method(nil) == :post
      assert Helpers.http_method(123, :delete) == :delete
    end
  end

  describe "stringify_keys/1" do
    test "deeply converts atom keys to strings" do
      assert Helpers.stringify_keys(%{a: 1, b: %{c: 2}}) == %{"a" => 1, "b" => %{"c" => 2}}
    end

    test "leaves string keys alone" do
      assert Helpers.stringify_keys(%{"a" => 1}) == %{"a" => 1}
    end

    test "passes lists through" do
      assert Helpers.stringify_keys([%{a: 1}, %{b: 2}]) == [%{"a" => 1}, %{"b" => 2}]
    end
  end

  describe "email_address/1" do
    test "extracts and lowercases the first email" do
      assert Helpers.email_address("Hello <Ada@Example.COM>") == "ada@example.com"
    end

    test "returns nil when no email is present" do
      assert Helpers.email_address("no email here") == nil
      assert Helpers.email_address(nil) == nil
    end
  end

  describe "email_domain/1" do
    test "extracts and lowercases the domain" do
      assert Helpers.email_domain("Ada <ada@Example.com>") == "example.com"
    end

    test "returns nil for malformed input" do
      assert Helpers.email_domain("no email") == nil
    end
  end

  describe "fetch_string_or_atom_key/3" do
    test "returns the value when the literal key is present" do
      assert Helpers.fetch_string_or_atom_key(%{"foo" => 1}, "foo") == 1
      assert Helpers.fetch_string_or_atom_key(%{foo: 1}, :foo) == 1
    end

    test "falls back to the alternate shape (string key with atom lookup)" do
      _ensure = :fetch_atom_test_key

      assert Helpers.fetch_string_or_atom_key(%{fetch_atom_test_key: 1}, "fetch_atom_test_key") ==
               1
    end

    test "falls back to the alternate shape (atom key with string lookup)" do
      assert Helpers.fetch_string_or_atom_key(%{"already_string" => 1}, :already_string) == 1
    end

    test "returns the default when neither shape is present" do
      assert Helpers.fetch_string_or_atom_key(%{"foo" => 1}, "bar") == nil
      assert Helpers.fetch_string_or_atom_key(%{"foo" => 1}, "bar", :default) == :default
    end

    test "returns the default for nil maps" do
      assert Helpers.fetch_string_or_atom_key(nil, "x", :missing) == :missing
    end

    test "does not grow the atom table for unknown keys" do
      random = "definitely_unknown_atom_#{System.unique_integer([:positive])}"
      # No matching entry, no rescue, no atom creation.
      assert Helpers.fetch_string_or_atom_key(%{}, random, :sentinel) == :sentinel
    end
  end

  describe "slugify_key/1" do
    test "trims, lowercases, and replaces dashes with underscores" do
      assert Helpers.slugify_key("  Phoenix-PubSub  ") == "phoenix_pubsub"
      assert Helpers.slugify_key("Aws-Sns") == "aws_sns"
    end

    test "passes atoms through unchanged" do
      assert Helpers.slugify_key(:already_atom) == :already_atom
    end

    test "returns nil for nil" do
      assert Helpers.slugify_key(nil) == nil
    end

    test "is idempotent" do
      assert Helpers.slugify_key(Helpers.slugify_key("Foo-Bar")) == "foo_bar"
    end
  end

  describe "atomize_existing_keys_strict/1" do
    test "atomizes a fully known map" do
      _ensure = :atomize_known_a
      _ensure = :atomize_known_b

      assert Helpers.atomize_existing_keys_strict(%{
               "atomize_known_a" => 1,
               "atomize_known_b" => 2
             }) ==
               %{atomize_known_a: 1, atomize_known_b: 2}
    end

    test "passes atom keys through" do
      assert Helpers.atomize_existing_keys_strict(%{a: 1, b: 2}) == %{a: 1, b: 2}
    end

    test "returns the original map unchanged when any key is unknown" do
      _ensure = :atomize_one_known
      random = "definitely_unknown_for_atomize_#{System.unique_integer([:positive])}"
      input = %{"atomize_one_known" => 1, random => 2}

      assert Helpers.atomize_existing_keys_strict(input) == input
    end
  end

  describe "property: atom_or_string/1" do
    property "atoms always pass through unchanged" do
      check all(atom <- StreamData.atom(:alphanumeric)) do
        assert Helpers.atom_or_string(atom) == atom
      end
    end

    property "unknown binaries return the binary unchanged (no atom-table growth)" do
      check all(suffix <- StreamData.string(:alphanumeric, min_length: 10, max_length: 30)) do
        random = "definitely_unknown_atom_#{suffix}_#{System.unique_integer([:positive])}"

        assert Helpers.atom_or_string(random) == random
      end
    end
  end

  describe "property: slugify_key/1" do
    property "output is always lowercase ASCII with no leading/trailing whitespace" do
      check all(
              input <-
                StreamData.one_of([
                  StreamData.constant(nil),
                  StreamData.atom(:alphanumeric),
                  StreamData.string(:alphanumeric, max_length: 20)
                ])
            ) do
        result = Helpers.slugify_key(input)

        case result do
          nil ->
            assert is_nil(input)

          atom when is_atom(atom) ->
            assert input == atom

          binary when is_binary(binary) ->
            assert binary == String.trim(binary)
            refute binary =~ "-"
            assert binary == String.downcase(binary)
        end
      end
    end

    property "is idempotent on string inputs" do
      check all(input <- StreamData.string(:alphanumeric, max_length: 20)) do
        once = Helpers.slugify_key(input)
        twice = Helpers.slugify_key(once)

        assert twice == once
      end
    end
  end

  describe "property: fetch_string_or_atom_key/3" do
    property "returns the stored value when looked up by either key shape" do
      check all(
              key_string <-
                StreamData.member_of(["foo", "bar", "baz", "qux"]),
              value <- StreamData.string(:printable),
              lookup_shape <- StreamData.member_of([:string, :atom])
            ) do
        atom_key = String.to_atom(key_string)
        string_map = %{key_string => value}
        atom_map = %{atom_key => value}

        lookup_key = if lookup_shape == :atom, do: atom_key, else: key_string

        assert Helpers.fetch_string_or_atom_key(string_map, lookup_key) == value
        assert Helpers.fetch_string_or_atom_key(atom_map, lookup_key) == value
      end
    end

    property "returns default when neither shape is present" do
      check all(
              key <- StreamData.member_of(["absent_a", "absent_b"]),
              default <-
                StreamData.one_of([StreamData.constant(nil), StreamData.atom(:alphanumeric)])
            ) do
        assert Helpers.fetch_string_or_atom_key(%{}, key, default) == default
      end
    end
  end

  describe "property: atomize_existing_keys_strict/1" do
    property "atomizes map when every binary key resolves to an existing atom" do
      check all(
              keys <-
                StreamData.list_of(StreamData.member_of(["alpha", "beta", "gamma"]),
                  max_length: 4
                ),
              values <- StreamData.list_of(StreamData.integer(), max_length: 4)
            ) do
        # Pre-existing atoms (referenced by name to ensure they exist)
        _ = [:alpha, :beta, :gamma]

        unique_keys = Enum.uniq(keys)
        pairs = Enum.zip(unique_keys, Enum.take(values ++ [0, 0, 0, 0], length(unique_keys)))
        input = Map.new(pairs)
        result = Helpers.atomize_existing_keys_strict(input)

        for {string_key, value} <- pairs do
          atom_key = String.to_existing_atom(string_key)
          assert Map.fetch!(result, atom_key) == value
        end
      end
    end

    property "returns the original map unchanged when any key is unknown" do
      check all(
              known <- StreamData.member_of(["alpha", "beta", "gamma"]),
              unknown_suffix <- StreamData.string(:alphanumeric, min_length: 10, max_length: 20)
            ) do
        _ = [:alpha, :beta, :gamma]
        unknown = "no_such_atom_#{unknown_suffix}_#{System.unique_integer([:positive])}"
        input = %{known => 1, unknown => 2}

        assert Helpers.atomize_existing_keys_strict(input) == input
      end
    end
  end
end
