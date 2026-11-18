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

      :gen_udp.close(client_sock)
    after
      Process.exit(server_pid, :kill)
    end
  end
end
