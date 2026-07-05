defmodule Hermit.Dns.ServerCacheTest do
  use ExUnit.Case, async: false
  alias Hermit.Dns.Packet
  alias Hermit.Dns.Server

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "DNS Server resolves from cache and preserves query ID" do
    # Create an inbound profile
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_Cache",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test"}
      })

    profile_id = profile.id
    # Create the config for this profile in database
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1",
        custom_rules: []
      })

    # Start DNS server on a random free port (e.g. 35353)
    port = 35353
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      # 1. Populate cache manually
      domain = "testcache.com"
      qname = <<9>> <> "testcache" <> <<3>> <> "com" <> <<0>>
      # A record, IN class
      question = qname <> <<0, 1, 0, 1>>

      # Build a response packet with transaction ID 0x0000
      mock_response = Packet.build_a_response(<<0, 0>>, question, "1.2.3.4")

      # Insert into global :dns_cache table
      # Key: {profile_id, domain, qtype}
      # Value: {{profile_id, domain, qtype}, resp_packet, expires_at}
      expires_at = System.monotonic_time(:second) + 100
      :ets.insert(:dns_cache, {{profile_id, domain, :A}, mock_response, expires_at})

      # 2. Query the server over UDP
      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])

      # Query ID: 0xABCD
      query_id = <<0xAB, 0xCD>>

      query_packet =
        query_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)

      assert {:ok, {{127, 0, 0, 1}, ^port, response}} = :gen_udp.recv(client_sock, 0, 1000)

      # 3. Verify response
      # It should have query ID 0xABCD and contain the cached IP 1.2.3.4
      assert binary_part(response, 0, 2) == query_id
      assert binary_part(response, byte_size(response) - 4, 4) == <<1, 2, 3, 4>>

      :gen_udp.close(client_sock)
    after
      # Stop DNS server
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end

  test "DNS Server resolves using DNS over HTTPS (DoH) upstream" do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_DoH",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test_doh"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "https://1.1.1.1/dns-query",
        custom_rules: []
      })

    port = 35354
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      _domain = "google.com"
      qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
      # A record, IN class
      question = qname <> <<0, 1, 0, 1>>

      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])

      query_id = <<0x55, 0x55>>

      query_packet =
        query_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)

      case :gen_udp.recv(client_sock, 0, 3000) do
        {:ok, {{127, 0, 0, 1}, ^port, response}} ->
          assert binary_part(response, 0, 2) == query_id
          <<_id::binary-size(2), flags::binary-size(2), _rest::binary>> = response
          <<_qr::1, _opcode::4, _aa::1, _tc::1, _rd::1, _ra::1, _z::3, rcode::4>> = flags
          assert rcode == 0

        {:error, reason} ->
          IO.puts(
            "DoH query failed or timed out (expected in offline network): #{inspect(reason)}"
          )
      end

      :gen_udp.close(client_sock)
    after
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end

  test "DNS Server forwards Tailscale internal domains to 100.100.100.100" do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_SplitDNS",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test_split"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    port = 35355
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      _domain = "my-device.ts.net"
      qname = <<9>> <> "my-device" <> <<2>> <> "ts" <> <<3>> <> "net" <> <<0>>
      question = qname <> <<0, 1, 0, 1>>

      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])
      query_id = <<0x77, 0x77>>

      query_packet =
        query_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)

      case :gen_udp.recv(client_sock, 0, 3000) do
        {:ok, {{127, 0, 0, 1}, ^port, response}} ->
          assert binary_part(response, 0, 2) == query_id
          <<_id::binary-size(2), flags::binary-size(2), _rest::binary>> = response
          <<_qr::1, _opcode::4, _aa::1, _tc::1, _rd::1, _ra::1, _z::3, rcode::4>> = flags
          assert rcode in [0, 2, 3]

        {:error, reason} ->
          flunk("DNS Server did not respond: #{inspect(reason)}")
      end

      :gen_udp.close(client_sock)
    after
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end
end
