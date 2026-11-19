defmodule Hermit.Vpn.SniProxyTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.SniProxy

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    SniProxy.init_table()
    # Clean up before each test
    :ets.delete_all_objects(:hermit_smart_routes)
    :ok
  end

  describe "route registration and matching" do
    test "matches exact domains" do
      SniProxy.register_routes("us_pair", ["netflix.com", "hulu.com"])

      assert SniProxy.match("netflix.com") == {:ok, "us_pair"}
      assert SniProxy.match("hulu.com") == {:ok, "us_pair"}
      assert SniProxy.match("other.com") == :nomatch
    end

    test "matches wildcard subdomains" do
      SniProxy.register_routes("ai_pair", ["*.openai.com", "chatgpt.com"])

      assert SniProxy.match("api.openai.com") == {:ok, "ai_pair"}
      assert SniProxy.match("auth.api.openai.com") == {:ok, "ai_pair"}
      assert SniProxy.match("openai.com") == {:ok, "ai_pair"}
      assert SniProxy.match("chatgpt.com") == {:ok, "ai_pair"}
      assert SniProxy.match("otheropenai.com") == :nomatch
    end

    test "unregister_pair removes all its routes" do
      SniProxy.register_routes("pair_a", ["a.com", "b.com"])
      SniProxy.register_routes("pair_b", ["c.com"])

      assert SniProxy.match("a.com") == {:ok, "pair_a"}
      assert SniProxy.match("c.com") == {:ok, "pair_b"}

      SniProxy.unregister_pair("pair_a")

      assert SniProxy.match("a.com") == :nomatch
      assert SniProxy.match("b.com") == :nomatch
      assert SniProxy.match("c.com") == {:ok, "pair_b"}
    end

    test "case insensitivity and whitespace trimming" do
      SniProxy.register_routes("test_pair", ["  NETFLIX.COM  ", "*.OpenAI.Com"])

      assert SniProxy.match("netflix.com") == {:ok, "test_pair"}
      assert SniProxy.match("NETFLIX.COM") == {:ok, "test_pair"}
      assert SniProxy.match("API.OPENAI.COM") == {:ok, "test_pair"}
    end

    test "all_routes filters out cache entries and returns only registered domains" do
      SniProxy.register_routes("test_pair", ["example.com"])
      # Manually insert an internal cache entry
      :ets.insert(:hermit_smart_routes, {{:__cache__, :internal_ips}, MapSet.new(), 999_999_999})
      :ets.insert(:hermit_smart_routes, {{:ports, "test_pair"}, 1080})

      routes = SniProxy.all_routes()
      assert {"example.com", "test_pair"} in routes
      # Ensure no internal cache tuples leaked
      for {k, v} <- routes do
        assert is_binary(k)
        assert is_binary(v)
      end
    end
  end

  describe "IpResolver caching and loop prevention" do
    alias Hermit.Vpn.SniProxy.IpResolver

    test "identifies netns veth IPs as internal" do
      assert IpResolver.internal_ip?({10, 200, 1, 2})
      assert IpResolver.internal_ip?("10.200.1.2")
      assert IpResolver.internal_ip?({10, 251, 1, 2})
      assert IpResolver.internal_ip?("10.251.1.2")
      refute IpResolver.internal_ip?("8.8.8.8")
      refute IpResolver.internal_ip?({8, 8, 8, 8})
    end

    test "caches internal IP resolution in ETS table" do
      IpResolver.clear_cache()
      # Trigger lookup which warms cache
      _ = IpResolver.internal_ip?({192, 168, 1, 100})

      # Assert cache entry exists in ETS
      assert [{{:__cache__, :internal_ips}, set, _exp}] =
               :ets.lookup(:hermit_smart_routes, {:__cache__, :internal_ips})

      assert is_struct(set, MapSet)

      # Calling clear_cache invalidates it
      IpResolver.clear_cache()
      assert [] = :ets.lookup(:hermit_smart_routes, {:__cache__, :internal_ips})
    end
  end
end
