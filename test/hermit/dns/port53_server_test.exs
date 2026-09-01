defmodule Hermit.Dns.Port53ServerTest do
  use ExUnit.Case, async: false
  alias Hermit.Dns.Server
  alias Hermit.Dns.Port53Server
  alias Hermit.Dns.Packet
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.DnsConfig

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})

    # Clear ETS caches
    if :ets.info(:ddns_client_ip_map) != :undefined do
      :ets.delete_all_objects(:ddns_client_ip_map)
    end

    if :ets.info(:dns_cache) != :undefined do
      :ets.delete_all_objects(:dns_cache)
    end

    {:ok, %{}}
  end

  test "delegates query resolution directly to Hermit.Dns.Server for mapped DDNS client" do
    # Create DNS Config with custom block rule
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "DDNS_Test_Profile",
        enabled: true,
        upstream_dns: "127.0.0.1",
        custom_rules: [
          %{"domain" => "blocked-by-rule.com", "action" => "block"},
          %{"domain" => "myhome.local", "action" => "redirect", "value" => "192.168.1.100"}
        ]
      })

    # Create DNS Endpoint with DDNS hostname
    {:ok, endpoint} =
      Hermit.Repo.insert(%DnsEndpoint{
        name: "DDNS_Test_Endpoint",
        doh_token: "ddns_token_test",
        ddns_hostname: "myrouter.ddns.net",
        dns_profile_id: config.id,
        enabled: true
      })

    endpoint_id = endpoint.id
    client_ip_str = "203.0.113.199"

    # Map client IP in DnsDdnsResolver ETS table
    :ets.insert(:ddns_client_ip_map, {{:ip, client_ip_str}, endpoint_id})

    # Start endpoint's Hermit.Dns.Server
    port = 38000 + endpoint_id
    {:ok, server_pid} = Server.start_link(endpoint_id: endpoint_id, port: port)

    # 1. Test Block Rule via DNS query packet
    qname = <<15>> <> "blocked-by-rule" <> <<3>> <> "com" <> <<0>>
    query_packet = <<0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>

    # Send query via Port53Server's resolution helper
    {:ok, client_ip_tuple} = :inet.parse_address(String.to_charlist(client_ip_str))
    res = Port53Server.resolve_via_endpoint_dns_server(endpoint_id, query_packet, client_ip_tuple)

    assert {:ok, resp_packet} = res
    # Check rcode 3 (NXDOMAIN)
    assert byte_size(resp_packet) >= 12
    <<_id::binary-size(2), _flags1::8, flags2::8, _rest::binary>> = resp_packet
    assert Bitwise.band(flags2, 0x0F) == 3

    # 2. Test Redirect Rule via DNS query packet
    qname2 = <<6>> <> "myhome" <> <<5>> <> "local" <> <<0>>
    query_packet2 = <<0, 2, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname2 <> <<0, 1, 0, 1>>

    res2 =
      Port53Server.resolve_via_endpoint_dns_server(endpoint_id, query_packet2, client_ip_tuple)

    assert {:ok, resp_packet2} = res2
    assert byte_size(resp_packet2) > 12

    # Clean up DNS server process
    GenServer.stop(server_pid)
  end

  test "serves from RAM cache when Hermit.Dns.Cache has cached answer" do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "DDNS_Cache_Profile",
        enabled: true,
        upstream_dns: "127.0.0.1"
      })

    {:ok, endpoint} =
      Hermit.Repo.insert(%DnsEndpoint{
        name: "DDNS_Cache_Endpoint",
        doh_token: "cache_token_test",
        ddns_hostname: "cache.ddns.net",
        dns_profile_id: config.id,
        enabled: true
      })

    endpoint_id = endpoint.id
    port = 38100 + endpoint_id
    {:ok, server_pid} = Server.start_link(endpoint_id: endpoint_id, port: port)

    domain = "port53cached.com"
    qname = <<12>> <> "port53cached" <> <<3>> <> "com" <> <<0>>
    query_packet = <<0, 99, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0>> <> qname <> <<0, 1, 0, 1>>
    query_rec = {:dns_query, domain, 1, 1}

    # Store mock response in cache
    mock_response = Packet.build_a_response(<<0, 99>>, query_rec, "8.8.4.4")
    expires_at = System.monotonic_time(:second) + 100

    :ets.insert(
      :dns_cache,
      {{endpoint_id, domain, :A}, mock_response, "resolved", "8.8.4.4", expires_at}
    )

    client_ip_tuple = {198, 51, 100, 1}

    assert {:ok, resp} =
             Port53Server.resolve_via_endpoint_dns_server(
               endpoint_id,
               query_packet,
               client_ip_tuple
             )

    assert resp == mock_response

    GenServer.stop(server_pid)
  end
end
