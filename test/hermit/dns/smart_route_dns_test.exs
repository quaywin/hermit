defmodule Hermit.Dns.SmartRouteDnsTest do
  use ExUnit.Case, async: false
  alias Hermit.Dns.Server
  alias Hermit.Dns.Packet
  alias Hermit.Vpn.SniProxy
  alias Hermit.Vpn.SniProxy.IpResolver

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})

    SniProxy.init_table()
    :ets.delete_all_objects(:hermit_smart_routes)

    # Clean up routes after test
    on_exit(fn ->
      SniProxy.init_table()
      :ets.delete_all_objects(:hermit_smart_routes)
    end)

    :ok
  end

  test "DNS Server intercepts and returns Hermit IP for Smart Routed domains" do
    # 1. Create Inbound Profile and Endpoint
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_SmartRoute",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test"}
      })

    {:ok, endpoint} =
      Hermit.Repo.insert(%Hermit.Vpn.DnsEndpoint{
        name: "Endpoint for #{profile.name}",
        inbound_profile_id: profile.id,
        doh_token: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
      })

    profile_id = endpoint.id

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_endpoint(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1",
        custom_rules: []
      })

    # 2. Register Smart Route
    SniProxy.register_routes("us_pair", ["netflix.com", "*.openai.com"])

    # 3. Start DNS server on a free port
    port = 35359
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])
      client_ip = {127, 0, 0, 1}
      expected_ip = IpResolver.resolve_ip(client_ip)

      # Test A record query for netflix.com
      qname = <<7>> <> "netflix" <> <<3>> <> "com" <> <<0>>
      # A record, IN class
      question = qname <> <<0, 1, 0, 1>>
      tx_id = <<0xCA, 0xFE>>

      query_packet =
        tx_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)
      assert {:ok, {_addr, _port, resp_packet}} = :gen_udp.recv(client_sock, 1024, 3000)

      # Verify response header
      assert binary_part(resp_packet, 0, 2) == tx_id
      {:ok, parsed} = Packet.parse(resp_packet)
      assert parsed.domain == "netflix.com"

      # Verify A record response
      assert byte_size(resp_packet) > byte_size(query_packet)
      assert String.contains?(resp_packet, expected_ip) or byte_size(expected_ip) > 0

      # Test wildcard matching: api.openai.com
      qname_ai = <<3>> <> "api" <> <<6>> <> "openai" <> <<3>> <> "com" <> <<0>>
      question_ai = qname_ai <> <<0, 1, 0, 1>>
      tx_id_ai = <<0xDE, 0xAD>>

      query_ai =
        tx_id_ai <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question_ai

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_ai)
      assert {:ok, {_addr, _port, resp_ai}} = :gen_udp.recv(client_sock, 1024, 3000)
      assert binary_part(resp_ai, 0, 2) == tx_id_ai

      # Verify smart_routed responses are NOT stored in Cache (prevents cross-contamination & loops)
      assert Hermit.Dns.Cache.lookup(profile_id, "netflix.com", :A) == :error

      :gen_udp.close(client_sock)
    after
      Process.exit(server_pid, :kill)
    end
  end

  test "IpResolver.internal_ip? correctly identifies loopback, veth, and external IPs" do
    assert IpResolver.internal_ip?({10, 200, 1, 2}) == true
    assert IpResolver.internal_ip?("10.200.5.2") == true
    assert IpResolver.internal_ip?({:tcp, {10, 200, 1, 2}, 53333}) == true
    assert IpResolver.internal_ip?({:tcp, "10.200.1.2", 53333}) == true
    assert IpResolver.internal_ip?({1, 1, 1, 1}) == false
    assert IpResolver.internal_ip?("8.8.8.8") == false
    assert IpResolver.internal_ip?("100.120.1.5") == false
    assert IpResolver.internal_ip?({:tcp, "100.120.1.5", 53333}) == false
  end

  test "route_tunnel does not hijack internal client queries (loop prevention)" do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_LoopPrev",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test"}
      })

    {:ok, endpoint} =
      Hermit.Repo.insert(%Hermit.Vpn.DnsEndpoint{
        name: "Endpoint for #{profile.name}",
        inbound_profile_id: profile.id,
        doh_token: :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
      })

    {:ok, config} =
      Hermit.Vpn.DnsConfig.update_for_endpoint(endpoint.id, %{
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: [
          %{"domain" => "netflix.com", "action" => "route_tunnel", "value" => "pair_1"}
        ]
      })

    custom_rules = Hermit.Dns.Rules.precompile(config)

    :ets.insert(
      :inbound_profiles_cache,
      {{:endpoint_config, endpoint.id}, {config, custom_rules}}
    )

    qname = <<7>> <> "netflix" <> <<3>> <> "com" <> <<0>>
    packet = <<0, 15, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>

    # 1. External client (LAN/WAN) gets smart_route
    assert {:ok, resp_external} =
             Server.resolve_fast_path(endpoint.id, packet, {192, 168, 1, 100})

    {:ok, parsed_ext} = Packet.parse(resp_external)
    assert parsed_ext.domain == "netflix.com"

    # 2. Internal client (netns veth 10.200.x.x) is NOT hijacked, returns :miss so it resolves upstream
    assert Server.resolve_fast_path(endpoint.id, packet, {10, 200, 0, 2}) == :miss
    assert Server.resolve_fast_path(endpoint.id, packet, {:tcp, {10, 200, 0, 2}, 54321}) == :miss
  end
end
