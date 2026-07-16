defmodule DripDrop.SequenceReadersTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{Fixtures, SequenceReaders}

  describe "get_sequence/2" do
    test "returns the tenant's sequence by key" do
      sequence = Fixtures.sequence_fixture(%{tenant_key: "tenant-a", key: "welcome"})

      assert %{id: id} = SequenceReaders.get_sequence("tenant-a", "welcome")
      assert id == sequence.id
    end

    test "returns nil when the key has not been provisioned for the tenant" do
      assert is_nil(SequenceReaders.get_sequence("tenant-a", "missing"))
    end

    test "does not return another tenant's sequence with the same key" do
      Fixtures.sequence_fixture(%{tenant_key: "tenant-b", key: "shared-key"})

      assert is_nil(SequenceReaders.get_sequence("tenant-a", "shared-key"))
    end

    test "fetches a global (tenant-less) sequence when tenant_key is nil" do
      global = Fixtures.sequence_fixture(%{tenant_key: nil, key: "global-welcome"})
      Fixtures.sequence_fixture(%{tenant_key: "tenant-a", key: "global-welcome"})

      assert %{id: id} = SequenceReaders.get_sequence(nil, "global-welcome")
      assert id == global.id
    end
  end

  describe "get_active_sequence_version/1 and get_active_sequence_version!/1" do
    test "returns the active version among draft, active, and archived versions" do
      sequence = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "archived"})
      active = Fixtures.sequence_version_fixture(sequence, %{version: 2, state: "active"})
      Fixtures.sequence_version_fixture(sequence, %{version: 3, state: "draft"})

      assert %{id: id} = SequenceReaders.get_active_sequence_version(sequence.id)
      assert id == active.id

      assert %{id: id} = SequenceReaders.get_active_sequence_version!(sequence.id)
      assert id == active.id
    end

    test "returns nil when no version is active" do
      sequence = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "draft"})

      assert is_nil(SequenceReaders.get_active_sequence_version(sequence.id))
    end

    test "bang variant raises when no version is active" do
      sequence = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "draft"})

      assert_raise Ecto.NoResultsError, fn ->
        SequenceReaders.get_active_sequence_version!(sequence.id)
      end
    end

    test "returns nil for a sequence with no versions at all" do
      sequence = Fixtures.sequence_fixture()

      assert is_nil(SequenceReaders.get_active_sequence_version(sequence.id))
    end
  end

  describe "max_version_number/1" do
    test "returns 0 when the sequence has no versions" do
      sequence = Fixtures.sequence_fixture()

      assert SequenceReaders.max_version_number(sequence.id) == 0
    end

    test "returns the highest authored version number" do
      sequence = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence, %{version: 1})
      Fixtures.sequence_version_fixture(sequence, %{version: 3, state: "archived"})
      Fixtures.sequence_version_fixture(sequence, %{version: 2, state: "archived"})

      assert SequenceReaders.max_version_number(sequence.id) == 3
    end

    test "does not count another sequence's versions" do
      sequence_a = Fixtures.sequence_fixture()
      sequence_b = Fixtures.sequence_fixture()
      Fixtures.sequence_version_fixture(sequence_a, %{version: 1})
      Fixtures.sequence_version_fixture(sequence_b, %{version: 5})

      assert SequenceReaders.max_version_number(sequence_a.id) == 1
    end
  end

  describe "latest_step_by_key/2" do
    test "returns nil when no version has ever contained that step key" do
      sequence = Fixtures.sequence_fixture()

      assert is_nil(SequenceReaders.latest_step_by_key(sequence.id, "missing"))
    end

    test "recovers a step from the newest prior version that still carries it" do
      sequence = Fixtures.sequence_fixture()
      v1 = Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "archived"})
      v2 = Fixtures.sequence_version_fixture(sequence, %{version: 2, state: "active"})

      old_step = Fixtures.step_fixture(v1, %{key: "invitation"})
      Fixtures.step_fixture(v2, %{key: "reminder"})

      assert %{id: id} = SequenceReaders.latest_step_by_key(sequence.id, "invitation")
      assert id == old_step.id
    end

    test "prefers the step from the newest version when the key exists in multiple versions" do
      sequence = Fixtures.sequence_fixture()
      v1 = Fixtures.sequence_version_fixture(sequence, %{version: 1, state: "archived"})
      v2 = Fixtures.sequence_version_fixture(sequence, %{version: 2, state: "active"})

      Fixtures.step_fixture(v1, %{key: "invitation", name: "Old invitation"})
      newest_step = Fixtures.step_fixture(v2, %{key: "invitation", name: "New invitation"})

      assert %{id: id} = SequenceReaders.latest_step_by_key(sequence.id, "invitation")
      assert id == newest_step.id
    end
  end

  describe "ordered_steps/1" do
    test "lists a version's steps in position order" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      third = Fixtures.step_fixture(version, %{key: "third", position: 3})
      first = Fixtures.step_fixture(version, %{key: "first", position: 1})
      second = Fixtures.step_fixture(version, %{key: "second", position: 2})

      assert SequenceReaders.ordered_steps(version.id) |> Enum.map(& &1.id) ==
               [first.id, second.id, third.id]
    end

    test "returns an empty list when the version has no steps" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      assert SequenceReaders.ordered_steps(version.id) == []
    end
  end

  describe "steps_by_key/1" do
    test "maps a version's steps by key" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      welcome = Fixtures.step_fixture(version, %{key: "welcome", position: 1})
      reminder = Fixtures.step_fixture(version, %{key: "reminder", position: 2})

      assert SequenceReaders.steps_by_key(version.id) == %{
               "welcome" => welcome,
               "reminder" => reminder
             }
    end

    test "returns an empty map when the version has no steps" do
      sequence = Fixtures.sequence_fixture()
      version = Fixtures.sequence_version_fixture(sequence)

      assert SequenceReaders.steps_by_key(version.id) == %{}
    end
  end
end
