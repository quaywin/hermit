defmodule Hermit.Vpn.Inbound.TailscaleTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.Inbound.Tailscale

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  describe "resolve_port/2" do
    test "uses ts_port directly when configured" do
      config = %{"ts_port" => "41655"}
      assert Tailscale.resolve_port("pair1", config) == 41655

      config_int = %{"ts_port" => 41660}
      assert Tailscale.resolve_port("pair1", config_int) == 41660
    end

    test "allocates port within custom ts_port_range" do
      config = %{"ts_port_range" => "42000-42010"}
      port = Tailscale.resolve_port("pair_abc", config)
      assert port >= 42000 and port <= 42010
    end

    test "allocates port within default range 41642-41700 when config is empty" do
      port = Tailscale.resolve_port("pair_xyz", %{})
      assert port >= 41642 and port <= 41700
    end
  end

  describe "append_advertise_args/3" do
    # Non-existent socket -> get_current_tags/2 safely returns [].
    @opts %{
      pair_id: "test_pair",
      wg_name: "hermit_wg_test_pair",
      socket_path: "/run/tailscaled.nonexistent.socket",
      advertise_exit_node: false
    }

    test "advertises custom subnet routes from config (bootstrap parity)" do
      config = %{"advertise_routes" => "192.168.1.0/24, 10.0.0.0/8"}

      args = Tailscale.append_advertise_args(["up", "--reset"], config, @opts)

      assert "--advertise-routes=192.168.1.0/24,10.0.0.0/8" in args
    end

    test "emits empty advertise-routes when no routes configured" do
      args = Tailscale.append_advertise_args(["up", "--reset"], %{}, @opts)

      assert "--advertise-routes=" in args
    end

    test "toggles advertise-exit-node from the flag" do
      on =
        Tailscale.append_advertise_args(
          ["up"],
          %{},
          Map.put(@opts, :advertise_exit_node, true)
        )

      assert "--advertise-exit-node" in on

      off =
        Tailscale.append_advertise_args(
          ["up"],
          %{},
          Map.put(@opts, :advertise_exit_node, false)
        )

      assert "--advertise-exit-node=false" in off
    end

    test "advertises default tag:hermit when auth key is an OAuth client secret" do
      config = %{"ts_auth_key" => "tskey-client-k123456-secret"}

      args = Tailscale.append_advertise_args(["up"], config, @opts)

      assert "--advertise-tags=tag:hermit" in args
    end

    test "advertises default tag:hermit when ts_auth_key is passed in opts" do
      opts = Map.put(@opts, :ts_auth_key, "tskey-client-oauth-key")

      args = Tailscale.append_advertise_args(["up"], %{}, opts)

      assert "--advertise-tags=tag:hermit" in args
    end

    test "advertises explicit custom tag when configured" do
      config = %{"advertise_tags" => "custom, tag:server"}

      args = Tailscale.append_advertise_args(["up"], config, @opts)

      assert "--advertise-tags=tag:custom,tag:server" in args
    end

    test "does not advertise tags when explicitly set to none" do
      config = %{"ts_auth_key" => "tskey-auth-normal-key", "advertise_tags" => "none"}

      args = Tailscale.append_advertise_args(["up"], config, @opts)

      refute Enum.any?(args, &String.starts_with?(&1, "--advertise-tags="))
    end
  end

  describe "resolve_tags/3 and oauth_auth_key?/1" do
    test "oauth_auth_key? detects client keys" do
      assert Tailscale.oauth_auth_key?("tskey-client-abc123")
      assert Tailscale.oauth_auth_key?("tskey-client-xyz?ephemeral=false")
      refute Tailscale.oauth_auth_key?("tskey-auth-12345")
      refute Tailscale.oauth_auth_key?("")
      refute Tailscale.oauth_auth_key?(nil)
    end

    test "resolve_tags normalizes tags and handles defaults" do
      assert Tailscale.resolve_tags("p1", %{"advertise_tags" => "my-tag"}) == "tag:my-tag"

      assert Tailscale.resolve_tags("p1", %{"advertise_tags" => "tag:my-tag, server"}) ==
               "tag:my-tag,tag:server"

      assert Tailscale.resolve_tags("p1", %{"advertise_tags" => "none"}) == nil
      assert Tailscale.resolve_tags("p1", %{"advertise_tags" => "false"}) == nil
      assert Tailscale.resolve_tags("p1", %{"ts_auth_key" => "tskey-client-abc"}) == "tag:hermit"
      assert Tailscale.resolve_tags("p1", %{"ts_auth_key" => "tskey-auth-abc"}) == "tag:hermit"
      assert Tailscale.resolve_tags("p1", %{}) == "tag:hermit"
    end
  end

  describe "get_api_token/1" do
    test "resolves direct API access token" do
      assert {:ok, "tskey-api-my-token"} = Tailscale.get_api_token("tskey-api-my-token")
    end

    test "resolves OAuth key via exchange in mock mode" do
      assert {:ok, _token} = Tailscale.get_api_token("tskey-client-k12345-secret")
    end

    test "resolves from map with ts_auth_key" do
      assert {:ok, _token} =
               Tailscale.get_api_token(%{"ts_auth_key" => "tskey-client-k12345-secret"})
    end

    test "rejects empty or nil keys" do
      assert {:error, :empty_key} = Tailscale.get_api_token("")
      assert {:error, :empty_key} = Tailscale.get_api_token("   ")
      assert {:error, :empty_key} = Tailscale.get_api_token(%{})
    end

    test "warns and returns error for tskey-auth-" do
      assert {:error, :unsupported_auth_key} = Tailscale.get_api_token("tskey-auth-xyz")
    end
  end

  describe "get_host_tailscale_ip/0" do
    test "returns nil or a valid ipv4 string without crashing" do
      result = Tailscale.get_host_tailscale_ip()

      assert is_nil(result) or
               (is_binary(result) and Regex.match?(~r/^\d+\.\d+\.\d+\.\d+$/, result))
    end
  end
end
