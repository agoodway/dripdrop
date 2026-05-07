defmodule DripDrop.Channels.Email.OAuthTokenTest do
  use ExUnit.Case, async: false

  alias DripDrop.Cache
  alias DripDrop.Channels.Email.OAuthToken

  describe "token callback caching" do
    test "caches callback tokens until expires_at" do
      adapter =
        adapter(fn -> token("cached-token", DateTime.add(DateTime.utc_now(), 60, :second)) end)

      assert {:ok, "cached-token"} = OAuthToken.get(adapter, :gmail)
      assert {:ok, "cached-token"} = OAuthToken.get(adapter, :gmail)
      assert Agent.get(adapter.credentials["counter"], & &1) == 1
    end

    test "refreshes on the next lookup after expiry" do
      adapter =
        adapter(fn count ->
          token("token-#{count}", DateTime.add(DateTime.utc_now(), 20, :millisecond))
        end)

      assert {:ok, "token-1"} = OAuthToken.get(adapter, :gmail)
      Process.sleep(50)
      assert {:ok, "token-2"} = OAuthToken.get(adapter, :gmail)
      assert Agent.get(adapter.credentials["counter"], & &1) == 2
    end

    test "does not call the callback more than once when expires_at is in the future" do
      for _index <- 1..25 do
        adapter =
          adapter(fn ->
            token(Ecto.UUID.generate(), DateTime.add(DateTime.utc_now(), 60, :second))
          end)

        assert {:ok, first_token} = OAuthToken.get(adapter, :ms365)
        assert {:ok, ^first_token} = OAuthToken.get(adapter, :ms365)
        assert Agent.get(adapter.credentials["counter"], & &1) == 1
      end
    end
  end

  defp adapter(callback) when is_function(callback) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    id = Ecto.UUID.generate()

    on_exit(fn ->
      Cache.delete({OAuthToken, :gmail, id})
      Cache.delete({OAuthToken, :ms365, id})
    end)

    %{
      id: id,
      credentials: %{"counter" => counter, "token_callback" => callback(counter, callback)}
    }
  end

  defp callback(counter, callback) when is_function(callback, 0) do
    fn _adapter ->
      Agent.update(counter, &(&1 + 1))
      callback.()
    end
  end

  defp callback(counter, callback) when is_function(callback, 1) do
    fn _adapter ->
      count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      callback.(count)
    end
  end

  defp token(access_token, expires_at) do
    {:ok, %{access_token: access_token, expires_at: expires_at}}
  end
end
