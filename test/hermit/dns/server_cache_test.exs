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
      query_rec = {:dns_query, domain, 1, 1}
      mock_response = Packet.build_a_response(<<0, 0>>, query_rec, "1.2.3.4")

      # Insert into global :dns_cache table
      # Key: {profile_id, domain, qtype}
      # Value: {{profile_id, domain, qtype}, resp_packet, status, answer_log_info, expires_at}
      expires_at = System.monotonic_time(:second) + 100

      :ets.insert(
        :dns_cache,
        {{profile_id, domain, :A}, mock_response, "resolved", "1.2.3.4", expires_at}
      )

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

  test "DNS Server blocks IPv6 AAAA queries when block_ipv6 is enabled" do
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_IPv6Block",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test_ipv6"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        block_ipv6: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    port = 35356
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      # google.com
      qname = <<6>> <> "google" <> <<3>> <> "com" <> <<0>>
      # AAAA record (28), IN class (1)
      question = qname <> <<0, 28, 0, 1>>

      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])
      query_id = <<0x99, 0x99>>
      query_packet =
        query_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)

      assert {:ok, {{127, 0, 0, 1}, ^port, response}} = :gen_udp.recv(client_sock, 0, 1000)

      # Verify response: NOERROR (rcode == 0) and 0 answers
      assert binary_part(response, 0, 2) == query_id
      <<_id::binary-size(2), flags::binary-size(2), _qdcount::16, ancount::16, _rest::binary>> = response
      <<_qr::1, _opcode::4, _aa::1, _tc::1, _rd::1, _ra::1, _z::3, rcode::4>> = flags

      assert rcode == 0
      assert ancount == 0

      :gen_udp.close(client_sock)
    after
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end

  test "DNS Server handles concurrent queries with duplicate Transaction IDs without collision" do
    # Start mock DNS upstream on a random port (active: false)
    {:ok, mock_sock} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_, mock_port}} = :inet.sockname(mock_sock)

    test_pid = self()
    mock_task = Task.async(fn ->
      mock_loop(mock_sock, test_pid)
    end)

    # Create config pointing to our mock upstream
    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_Collision",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test_collision"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1:#{mock_port}",
        custom_rules: [],
        enable_query_logging: false
      })

    port = 35357
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      # Client 1 query domain1.com
      qname1 = <<7>> <> "domain1" <> <<3>> <> "com" <> <<0>>
      question1 = qname1 <> <<0, 1, 0, 1>>
      
      # Client 2 query domain2.com
      qname2 = <<7>> <> "domain2" <> <<3>> <> "com" <> <<0>>
      question2 = qname2 <> <<0, 1, 0, 1>>

      {:ok, client_sock1} = :gen_udp.open(0, [:binary, active: false])
      {:ok, client_sock2} = :gen_udp.open(0, [:binary, active: false])

      # BOTH CLIENTS USE THE SAME TRANSACTION ID (0x1111)
      shared_tx_id = <<0x11, 0x11>>

      query_packet1 =
        shared_tx_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question1

      query_packet2 =
        shared_tx_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question2

      # Send Query 1 (domain1.com, delay 200ms in upstream)
      :ok = :gen_udp.send(client_sock1, {127, 0, 0, 1}, port, query_packet1)
      
      # Wait a tiny bit (20ms) to ensure it reaches GenServer, then send Query 2 (domain2.com, delay 50ms)
      Process.sleep(20)
      :ok = :gen_udp.send(client_sock2, {127, 0, 0, 1}, port, query_packet2)

      # Wait for response on Client 2 (should respond first due to shorter delay)
      assert {:ok, {{127, 0, 0, 1}, ^port, response2}} = :gen_udp.recv(client_sock2, 0, 1000)
      assert binary_part(response2, 0, 2) == shared_tx_id
      assert binary_part(response2, byte_size(response2) - 4, 4) == <<2, 2, 2, 2>>

      # Wait for response on Client 1 (should respond second)
      assert {:ok, {{127, 0, 0, 1}, ^port, response1}} = :gen_udp.recv(client_sock1, 0, 1500)
      assert binary_part(response1, 0, 2) == shared_tx_id
      assert binary_part(response1, byte_size(response1) - 4, 4) == <<1, 1, 1, 1>>

      :gen_udp.close(client_sock1)
      :gen_udp.close(client_sock2)
    after
      :gen_udp.close(mock_sock)
      Task.shutdown(mock_task)
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end

  test "DNS Server serve stale cache when upstream times out (Serve-Stale)" do
    # Start mock DNS upstream on a random port that will NOT respond (simulating timeout)
    {:ok, mock_sock} = :gen_udp.open(0, [:binary, active: false])
    {:ok, {_, mock_port}} = :inet.sockname(mock_sock)

    test_pid = self()
    mock_task = Task.async(fn ->
      # Mock loop does nothing on receive to cause timeout
      mock_timeout_loop(mock_sock, test_pid)
    end)

    {:ok, profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "P_Test_Stale",
        type: "tailscale",
        config: %{"ts_auth_key" => "k_test_stale"}
      })

    profile_id = profile.id
    _config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(profile_id, %{
        enabled: true,
        upstream_dns: "127.0.0.1:#{mock_port}",
        custom_rules: [],
        enable_query_logging: false
      })

    port = 35358
    {:ok, server_pid} = Server.start_link(profile_id: profile_id, port: port)

    try do
      # 1. Populate stale cache manually (expires_at is in the past)
      domain = "stale-test.com"
      qname = <<10>> <> "stale-test" <> <<3>> <> "com" <> <<0>>
      question = qname <> <<0, 1, 0, 1>>

      query_rec = {:dns_query, domain, 1, 1}
      mock_response = Packet.build_a_response(<<0, 0>>, query_rec, "9.9.9.9")

      # Expired 10 seconds ago
      expires_at = System.monotonic_time(:second) - 10
      :ets.insert(
        :dns_cache,
        {{profile_id, domain, :A}, mock_response, "resolved", "9.9.9.9", expires_at}
      )

      # 2. Query the server over UDP
      {:ok, client_sock} = :gen_udp.open(0, [:binary, active: false])
      query_id = <<0xDE, 0xAD>>
      query_packet =
        query_id <> <<0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <> question

      :ok = :gen_udp.send(client_sock, {127, 0, 0, 1}, port, query_packet)

      # Hermit has 2s timeout for upstream queries in Server.clean_timeouts
      # Wait enough for it to trigger timeout fallback (up to 3 seconds)
      assert {:ok, {{127, 0, 0, 1}, ^port, response}} = :gen_udp.recv(client_sock, 0, 4000)

      # Verify response contains the stale IP "9.9.9.9" and client's query ID 0xDEAD
      assert binary_part(response, 0, 2) == query_id
      assert binary_part(response, byte_size(response) - 4, 4) == <<9, 9, 9, 9>>

      :gen_udp.close(client_sock)
    after
      :gen_udp.close(mock_sock)
      Task.shutdown(mock_task)
      if Process.alive?(server_pid) do
        GenServer.stop(server_pid)
      end
    end
  end

  defp mock_timeout_loop(sock, parent_pid) do
    case :gen_udp.recv(sock, 0, 100) do
      {:ok, _} -> mock_timeout_loop(sock, parent_pid)
      _ -> mock_timeout_loop(sock, parent_pid)
    end
  end

  defp mock_loop(sock, parent_pid) do
    case :gen_udp.recv(sock, 0, 1000) do
      {:ok, {ip, port, packet}} ->
        IO.inspect({ip, port, byte_size(packet)}, label: "Mock Upstream Received UDP Packet")
        case Packet.parse(packet) do
          {:ok, %{domain: domain, id: id_bin, query_record: query_rec}} ->
            IO.inspect(domain, label: "Parsed Domain in Mock Upstream")
            spawn(fn ->
              delay = if domain == "domain1.com", do: 200, else: 50
              ip_str = if domain == "domain1.com", do: "1.1.1.1", else: "2.2.2.2"
              Process.sleep(delay)
              response = Packet.build_a_response(id_bin, query_rec, ip_str)
              IO.inspect({ip, port, ip_str}, label: "Mock Upstream sending response back")
              :gen_udp.send(sock, ip, port, response)
            end)
          other ->
            IO.inspect(other, label: "Packet.parse failed in Mock Upstream")
            :ok
        end
        mock_loop(sock, parent_pid)

      {:error, :timeout} ->
        mock_loop(sock, parent_pid)

      {:error, _reason} ->
        :ok
    end
  end
end
