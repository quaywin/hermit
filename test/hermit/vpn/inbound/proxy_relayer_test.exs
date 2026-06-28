defmodule Hermit.Vpn.Inbound.Proxy.RelayerTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.Inbound.Proxy.Relayer

  setup do
    # Create a unique temporary directory for the proxy config/info files
    storage_dir =
      Path.expand("storage/test_proxy_relayer_#{System.unique_integer([:positive])}", File.cwd!())

    File.mkdir_p!(storage_dir)

    # Configure Docker config to mock: true
    original_config = Application.get_env(:hermit, :docker, [])
    Application.put_env(:hermit, :docker, Keyword.put(original_config, :mock, true))

    on_exit(fn ->
      Application.put_env(:hermit, :docker, original_config)
      File.rm_rf!(storage_dir)
    end)

    %{storage_dir: storage_dir}
  end

  test "relays HTTP and SOCKS5 connections in mock mode", %{storage_dir: storage_dir} do
    # Start the proxy relayer
    # Since mock is true, port defaults to 0 (ephemeral port assigned by OS)
    {:ok, pid} =
      Relayer.start_link(
        pair_id: "test_pair_proxy",
        storage_dir: storage_dir,
        port: 0
      )

    # Allow the GenServer to write the file and start listening
    Process.sleep(50)

    # Read proxy info JSON to get the port
    info_path = Path.join(storage_dir, "proxy_info.json")
    assert File.exists?(info_path)
    info = Jason.decode!(File.read!(info_path))
    port = info["port"]
    assert is_integer(port)
    assert port > 0

    # 1. Test HTTP Proxy Protocol Signature (Non-SOCKS5)
    assert {:ok, http_sock} =
             :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

    assert :ok = :gen_tcp.send(http_sock, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert {:ok, http_resp} = :gen_tcp.recv(http_sock, 0, 2000)
    assert http_resp =~ "Mock Proxy"
    :gen_tcp.close(http_sock)

    # 2. Test SOCKS5 Protocol Signature
    assert {:ok, socks_sock} =
             :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

    # Send initial greeting: SOCKS version 5, 1 auth method (no auth)
    assert :ok = :gen_tcp.send(socks_sock, <<0x05, 0x01, 0x00>>)
    assert {:ok, <<0x05, 0x00>>} = :gen_tcp.recv(socks_sock, 2, 2000)

    # Send connect request: SOCKS version 5, Connect command (0x01), RSV (0x00), IPv4 type (0x01), IP 127.0.0.1 (4 bytes), Port 80 (2 bytes)
    assert :ok = :gen_tcp.send(socks_sock, <<0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0, 80>>)

    # Expect success response: SOCKS version 5, Success status (0x00), RSV, IPv4, 4 bytes IP, 2 bytes port (total 10 bytes)
    assert {:ok, <<0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0>>} =
             :gen_tcp.recv(socks_sock, 10, 2000)

    # Now test the echo loop in the mock handler
    assert :ok = :gen_tcp.send(socks_sock, "hello world")
    assert {:ok, "hello world"} = :gen_tcp.recv(socks_sock, 0, 2000)

    :gen_tcp.close(socks_sock)

    # Clean up the process
    GenServer.stop(pid)
  end
end
