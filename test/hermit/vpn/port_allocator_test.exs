defmodule Hermit.Vpn.PortAllocatorTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.PortAllocator

  test "allocates two consecutive free ports in range" do
    assert {:ok, socks_port, http_port} = PortAllocator.allocate_free_ports()
    assert is_integer(socks_port)
    assert is_integer(http_port)
    assert socks_port >= 10000 and socks_port <= 10199
    assert http_port >= 10000 and http_port <= 10199
    assert http_port == socks_port + 1
  end

  test "detects occupied ports and skips them" do
    # Listen on a port in the range to mock it being occupied
    # Let's pick port 10050
    port = 10050

    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        try do
          assert {:ok, socks_port, http_port} = PortAllocator.allocate_free_ports()
          # The allocator should not return port 10050 or 10049 (since P+1 would be 10050)
          refute socks_port == port
          refute http_port == port
        after
          :gen_tcp.close(socket)
        end

      _ ->
        # If we cannot bind to the port (e.g. system permissions or already in use), skip the assertion
        :ok
    end
  end
end
