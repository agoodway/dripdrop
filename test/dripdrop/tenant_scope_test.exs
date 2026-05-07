defmodule DripDrop.TenantScopeTest do
  use DripDrop.DataCase, async: false

  alias DripDrop.{Fixtures, HttpHook, TestRepo}

  describe "tenant-scoped query guards" do
    test "query helpers reject omitted tenant scope" do
      sequence = Fixtures.sequence_fixture()

      helpers = [
        {:list_channel_adapters, fn -> DripDrop.list_channel_adapters(%{}) end},
        {:list_active_enrollments, fn -> DripDrop.list_active_enrollments(%{}) end},
        {:get_enrollment, fn -> DripDrop.get_enrollment(sequence.id, "user", "ada") end},
        {:list_http_hooks, fn -> DripDrop.list_http_hooks(sequence.id) end}
      ]

      for {helper, call} <- helpers do
        assert_raise ArgumentError, ~r/#{helper} requires an explicit :tenant_key/, call
      end
    end

    test "explicit tenant scope filters adapter lists" do
      tenant_adapter = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-a"})
      _other_tenant = Fixtures.channel_adapter_fixture(%{tenant_key: "tenant-b"})
      global_adapter = Fixtures.channel_adapter_fixture(%{tenant_key: nil})

      assert [adapter] = DripDrop.list_channel_adapters(%{tenant_key: "tenant-a"})
      assert adapter.id == tenant_adapter.id

      assert [adapter] = DripDrop.list_channel_adapters(%{tenant_key: nil})
      assert adapter.id == global_adapter.id
    end

    test "explicit tenant scope filters enrollment lists and lookups" do
      tenant_a = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      version_a = Fixtures.sequence_version_fixture(tenant_a)

      tenant_b = Fixtures.sequence_fixture(%{tenant_key: "tenant-b"})
      version_b = Fixtures.sequence_version_fixture(tenant_b)

      enrollment_a =
        Fixtures.enrollment_fixture(tenant_a, version_a, %{
          subscriber_type: "user",
          subscriber_id: "same"
        })

      _enrollment_b =
        Fixtures.enrollment_fixture(tenant_b, version_b, %{
          subscriber_type: "user",
          subscriber_id: "same"
        })

      assert [enrollment] = DripDrop.list_active_enrollments(%{tenant_key: "tenant-a"})
      assert enrollment.id == enrollment_a.id

      assert DripDrop.get_enrollment(tenant_a.id, "user", "same", "tenant-a").id ==
               enrollment_a.id

      refute DripDrop.get_enrollment(tenant_a.id, "user", "same", "tenant-b")
    end

    test "explicit tenant scope filters HTTP hook lists" do
      tenant_a = Fixtures.sequence_fixture(%{tenant_key: "tenant-a"})
      tenant_b = Fixtures.sequence_fixture(%{tenant_key: "tenant-b"})

      hook_a = Fixtures.http_hook_fixture(tenant_a.id, %{tenant_key: "tenant-a", key: "a"})

      _hook_b =
        Fixtures.http_hook_fixture(tenant_b.id, %{
          tenant_key: "tenant-b",
          key: "b",
          url: "https://hooks.example.test/b"
        })

      global_hook =
        %HttpHook{}
        |> HttpHook.changeset(%{
          sequence_id: tenant_a.id,
          tenant_key: nil,
          name: "Global",
          key: "global",
          method: "POST",
          url: "https://hooks.example.test/global",
          timeout_ms: 1_000,
          retry_count: 0,
          auth_type: "none",
          headers: %{},
          response_type: "json",
          active: true
        })
        |> TestRepo.insert!()

      assert [hook] = DripDrop.list_http_hooks(tenant_a.id, "tenant-a")
      assert hook.id == hook_a.id

      assert [hook] = DripDrop.list_http_hooks(tenant_a.id, nil)
      assert hook.id == global_hook.id
    end
  end
end
