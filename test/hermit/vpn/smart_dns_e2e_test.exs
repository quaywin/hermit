defmodule Hermit.Vpn.SmartDnsE2ETest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.SniProxy
  alias Hermit.Vpn.SniProxy.Server

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})

    SniProxy.init_table()
    :ets.delete_all_objects(:hermit_smart_routes)

    # Initialize :dns_proxy_cache ETS table if not existing
    if :ets.info(:dns_proxy_cache) == :undefined do
      :ets.new(:dns_proxy_cache, [:named_table, :public, :set])
    end

    on_exit(fn ->
      SniProxy.init_table()
      :ets.delete_all_objects(:hermit_smart_routes)
    end)

    :ok
  end

  test "end-to-end TLS SNI extraction, SOCKS5 handshake, and bi-directional TCP relay" do
    # 1. Start a Mock SOCKS5 server on a random free port
    {:ok, socks_listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, socks_port} = :inet.port(socks_listener)

    # Mock SOCKS5 process that accepts connection, handles handshake, and echoes data
    test_pid = self()

    mock_socks_task =
      Task.async(fn ->
        {:ok, s_client} = :gen_tcp.accept(socks_listener, 3000)

        # 1. Method negotiation: receive <<5, 1, 0>>, send <<5, 0>>
        assert {:ok, <<0x05, 0x01, 0x00>>} = :gen_tcp.recv(s_client, 3, 3000)
        :ok = :gen_tcp.send(s_client, <<0x05, 0x00>>)

        # 2. CONNECT request: expect connect to stream.netflix.com:443
        assert {:ok, <<0x05, 0x01, 0x00, 0x03, domain_len::8>>} = :gen_tcp.recv(s_client, 5, 3000)
        assert {:ok, rest} = :gen_tcp.recv(s_client, domain_len + 2, 3000)
        domain = binary_part(rest, 0, domain_len)
        assert domain == "stream.netflix.com"
        assert <<443::16>> == binary_part(rest, domain_len, 2)

        # Send SOCKS5 success response: <<5, 0, 0, 1, 127, 0, 0, 1, 443::16>>
        :ok = :gen_tcp.send(s_client, <<0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 443::16>>)

        # 3. Receive the initial TLS ClientHello
        assert {:ok, client_hello} = :gen_tcp.recv(s_client, 0, 3000)
        assert byte_size(client_hello) > 0
        send(test_pid, {:mock_socks_received_hello, domain})

        # Echo a mock TLS ServerHello response back
        mock_server_response = "MOCK_TLS_SERVER_HELLO_FROM_NETFLIX"
        :ok = :gen_tcp.send(s_client, mock_server_response)

        # Clean up
        :timer.sleep(100)
        :gen_tcp.close(s_client)
      end)

    # 2. Start SNI Proxy on ephemeral ports
    {:ok, https_probe} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, test_https_port} = :inet.port(https_probe)
    :gen_tcp.close(https_probe)

    {:ok, http_probe} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, test_http_port} = :inet.port(http_probe)
    :gen_tcp.close(http_probe)

    {:ok, proxy_pid} =
      Server.start_link(
        name: false,
        enabled: true,
        https_port: test_https_port,
        http_port: test_http_port
      )

    # 3. Register route and mock proxy port in cache
    pair_id = "test_e2e_pair"
    SniProxy.register_routes(pair_id, ["*.netflix.com"])
    :ets.insert(:dns_proxy_cache, {{:ports, pair_id}, {8080, socks_port}})

    # Small sleep to let listener bind
    :timer.sleep(100)

    try do
      # 4. Connect to SNI Proxy as a client and send TLS ClientHello
      {:ok, client_socket} =
        :gen_tcp.connect({127, 0, 0, 1}, test_https_port, [:binary, active: false], 3000)

      packet = build_tls_client_hello("stream.netflix.com")
      :ok = :gen_tcp.send(client_socket, packet)

      # 5. Verify mock SOCKS5 received the handshake and domain
      assert_receive {:mock_socks_received_hello, "stream.netflix.com"}, 3000

      # 6. Verify client receives the response echoed back through the relay
      assert {:ok, response} = :gen_tcp.recv(client_socket, 0, 3000)
      assert response == "MOCK_TLS_SERVER_HELLO_FROM_NETFLIX"

      :gen_tcp.close(client_socket)
      Task.await(mock_socks_task, 3000)
    after
      if is_pid(proxy_pid) and Process.alive?(proxy_pid) do
        Process.unlink(proxy_pid)
        GenServer.stop(proxy_pid, :normal, 1000)
      end

      :gen_tcp.close(socks_listener)
    end
  end

  defp build_tls_client_hello(hostname) do
    host_bytes = hostname
    host_len = byte_size(host_bytes)
    server_name = <<0::8, host_len::16, host_bytes::binary>>
    server_name_list = <<byte_size(server_name)::16, server_name::binary>>

    sni_ext = <<0x0000::16, byte_size(server_name_list)::16, server_name_list::binary>>
    extensions_block = <<byte_size(sni_ext)::16, sni_ext::binary>>

    random = :crypto.strong_rand_bytes(32)
    ciphers = <<0x1301::16>>
    cipher_block = <<byte_size(ciphers)::16, ciphers::binary>>
    compression_block = <<1::8, 0::8>>
    session_id_block = <<0::8>>

    client_hello_body = <<
      0x0303::16,
      random::binary,
      session_id_block::binary,
      cipher_block::binary,
      compression_block::binary,
      extensions_block::binary
    >>

    handshake = <<0x01::8, byte_size(client_hello_body)::24, client_hello_body::binary>>
    <<0x16::8, 0x0301::16, byte_size(handshake)::16, handshake::binary>>
  end
end
