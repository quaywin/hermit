defmodule Hermit.Vpn.SniProxyTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.SniProxy

  setup do
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
  end
end
