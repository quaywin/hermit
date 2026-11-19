defmodule Hermit.Vpn.SniProxy.Handler do
  @moduledoc """
  Handles an incoming TCP connection on the SNI Proxy (ports 443 / 80).
  Inspects the initial packet, resolves target domain and tunnel pair,
  initiates SOCKS5 handshake, and relays traffic bi-directionally.
  """
  require Logger
  alias Hermit.Vpn.SniProxy
  alias Hermit.Vpn.SniProxy.Parser

  @doc """
  Main entry point for handling a client socket connection.
  """
  @spec handle(port(), pos_integer()) :: :ok
  def handle(client_socket, default_target_port) do
    # Prevent recursive connection loop if connection originates from Hermit itself
    case :inet.peername(client_socket) do
      {:ok, {peer_ip, _peer_port}} ->
        if SniProxy.IpResolver.internal_ip?(peer_ip) do
          Logger.warning(
            "SNI Proxy: Loop prevented! Connection rejected from internal IP #{inspect(peer_ip)}"
          )

          :gen_tcp.close(client_socket)
          :ok
        else
          do_handle(client_socket, default_target_port)
        end

      _ ->
        do_handle(client_socket, default_target_port)
    end
  end

  defp do_handle(client_socket, default_target_port) do
    # Read the initial packet with a 5-second timeout
    case :gen_tcp.recv(client_socket, 0, 5000) do
      {:ok, initial_packet} ->
        case Parser.extract_host(initial_packet) do
          {:ok, host} ->
            route_connection(client_socket, host, default_target_port, initial_packet)

          {:error, reason} ->
            Logger.debug(
              "SNI Proxy: Failed to parse host from initial packet: #{inspect(reason)}"
            )

            :gen_tcp.close(client_socket)
            :ok
        end

      {:error, reason} ->
        Logger.debug("SNI Proxy: Client recv failed before handshake: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
        :ok
    end
  end

  defp route_connection(client_socket, host, target_port, initial_packet) do
    case SniProxy.match(host) do
      {:ok, pair_id} ->
        case SniProxy.get_socks5_port(pair_id) do
          {:ok, socks5_port} ->
            connect_and_relay(
              client_socket,
              host,
              target_port,
              initial_packet,
              socks5_port,
              pair_id
            )

          {:error, reason} ->
            Logger.error(
              "SNI Proxy: SOCKS5 proxy port not available for pair #{pair_id}: #{inspect(reason)}"
            )

            :gen_tcp.close(client_socket)
            :ok
        end

      :nomatch ->
        Logger.debug("SNI Proxy: No tunnel route matched for domain: #{host}")
        # If it was an HTTP request (port 80), send a friendly 404
        if target_port == 80 do
          response =
            "HTTP/1.1 404 Not Found\r\n" <>
              "Content-Type: text/plain\r\n" <>
              "Connection: close\r\n\r\n" <>
              "Domain #{host} is not configured for Smart Routing on Hermit.\n"

          _ = :gen_tcp.send(client_socket, response)
        end

        :gen_tcp.close(client_socket)
        :ok
    end
  end

  defp connect_and_relay(client_socket, host, target_port, initial_packet, socks5_port, pair_id) do
    connect_opts = [
      :binary,
      packet: :raw,
      active: false,
      nodelay: true,
      buffer: 65_536,
      recbuf: 65_536,
      sndbuf: 65_536,
      keepalive: true,
      send_timeout: 10_000,
      send_timeout_close: true
    ]

    case :gen_tcp.connect({127, 0, 0, 1}, socks5_port, connect_opts, 5000) do
      {:ok, target_socket} ->
        case socks5_handshake(target_socket, host, target_port) do
          :ok ->
            # Send initial packet (ClientHello or HTTP request) to target
            case :gen_tcp.send(target_socket, initial_packet) do
              :ok ->
                # Configure client socket buffer and start bi-directional streaming loop
                :inet.setopts(
                  client_socket,
                  buffer: 65_536,
                  recbuf: 65_536,
                  sndbuf: 65_536,
                  nodelay: true,
                  keepalive: true,
                  send_timeout: 10_000,
                  send_timeout_close: true,
                  active: 32
                )

                :inet.setopts(target_socket, active: 32)
                relay_loop(client_socket, target_socket)

              {:error, _} ->
                :gen_tcp.close(client_socket)
                :gen_tcp.close(target_socket)
                :ok
            end

          {:error, {:socks5_rep_error, rep}} ->
            # Network unreachable (3), Host unreachable (4), Connection refused (5) are remote network conditions (e.g. IPv6-only host)
            log_fn = if rep in [3, 4, 5], do: &Logger.warning/1, else: &Logger.error/1

            log_fn.(
              "SNI Proxy: SOCKS5 connection to #{host}:#{target_port} via tunnel #{pair_id} failed: #{socks5_rep_description(rep)} (code #{rep})"
            )

            :gen_tcp.close(client_socket)
            :gen_tcp.close(target_socket)
            :ok

          {:error, handshake_err} ->
            Logger.warning(
              "SNI Proxy: SOCKS5 handshake to #{host}:#{target_port} via tunnel #{pair_id} failed: #{inspect(handshake_err)}"
            )

            :gen_tcp.close(client_socket)
            :gen_tcp.close(target_socket)
            :ok
        end

      {:error, reason} ->
        Logger.error(
          "SNI Proxy: Failed to connect to SOCKS5 port #{socks5_port} for pair #{pair_id}: #{inspect(reason)}"
        )

        :gen_tcp.close(client_socket)
        :ok
    end
  end

  # Performs RFC 1928 SOCKS5 Client Handshake
  defp socks5_handshake(socket, host, port) do
    # 1. Method negotiation: SOCKS v5, 1 method, NO AUTH (0x00)
    case :gen_tcp.send(socket, <<0x05, 0x01, 0x00>>) do
      :ok ->
        case :gen_tcp.recv(socket, 2, 5000) do
          {:ok, <<0x05, 0x00>>} ->
            send_connect_command(socket, host, port)

          {:ok, other} ->
            {:error, {:unsupported_socks5_auth, other}}

          {:error, reason} ->
            {:error, {:socks5_auth_recv_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:socks5_auth_send_failed, reason}}
    end
  end

  defp send_connect_command(_socket, host, _port)
       when byte_size(host) == 0 or byte_size(host) > 255 do
    {:error, :invalid_host_length}
  end

  defp send_connect_command(socket, host, port) do
    host_len = byte_size(host)
    # CMD = 0x01 (CONNECT), RSV = 0x00, ATYP = 0x03 (Domain name)
    req = <<0x05, 0x01, 0x00, 0x03, host_len::8, host::binary, port::16>>

    case :gen_tcp.send(socket, req) do
      :ok ->
        case :gen_tcp.recv(socket, 4, 5000) do
          {:ok, <<0x05, 0x00, 0x00, atyp::8>>} ->
            consume_bind_addr(socket, atyp)

          {:ok, <<0x05, rep::8, _rest::binary>>} ->
            {:error, {:socks5_rep_error, rep}}

          {:error, reason} ->
            {:error, {:socks5_conn_recv_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:socks5_conn_send_failed, reason}}
    end
  end

  defp consume_bind_addr(socket, 0x01) do
    # IPv4 (4 bytes) + port (2 bytes) = 6 bytes
    case :gen_tcp.recv(socket, 6, 3000) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp consume_bind_addr(socket, 0x03) do
    # Domain length (1 byte)
    case :gen_tcp.recv(socket, 1, 3000) do
      {:ok, <<len::8>>} ->
        # Domain (len bytes) + port (2 bytes)
        case :gen_tcp.recv(socket, len + 2, 3000) do
          {:ok, _} -> :ok
          err -> err
        end

      err ->
        err
    end
  end

  defp consume_bind_addr(socket, 0x04) do
    # IPv6 (16 bytes) + port (2 bytes) = 18 bytes
    case :gen_tcp.recv(socket, 18, 3000) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp consume_bind_addr(_socket, _atyp), do: {:error, :unknown_atyp}

  defp socks5_rep_description(1), do: "general SOCKS server failure"
  defp socks5_rep_description(2), do: "connection not allowed by ruleset"

  defp socks5_rep_description(3),
    do: "network unreachable (destination may lack IPv4/IPv6 route in tunnel)"

  defp socks5_rep_description(4), do: "host unreachable"
  defp socks5_rep_description(5), do: "connection refused by destination"
  defp socks5_rep_description(6), do: "TTL expired"
  defp socks5_rep_description(7), do: "command not supported"
  defp socks5_rep_description(8), do: "address type not supported"
  defp socks5_rep_description(code), do: "error code #{code}"

  # Bi-directional TCP relay loop using batched active: N to minimize setopts syscalls
  defp relay_loop(client, target) do
    receive do
      {:tcp, ^client, data} ->
        case :gen_tcp.send(target, data) do
          :ok ->
            relay_loop(client, target)

          {:error, _} ->
            cleanup(client, target)
        end

      {:tcp, ^target, data} ->
        case :gen_tcp.send(client, data) do
          :ok ->
            relay_loop(client, target)

          {:error, _} ->
            cleanup(client, target)
        end

      {:tcp_passive, ^client} ->
        :inet.setopts(client, active: 32)
        relay_loop(client, target)

      {:tcp_passive, ^target} ->
        :inet.setopts(target, active: 32)
        relay_loop(client, target)

      {:tcp_closed, ^client} ->
        cleanup(client, target)

      {:tcp_closed, ^target} ->
        cleanup(client, target)

      {:tcp_error, ^client, _reason} ->
        cleanup(client, target)

      {:tcp_error, ^target, _reason} ->
        cleanup(client, target)

      _other ->
        relay_loop(client, target)
    after
      60_000 ->
        # Idle timeout: 60s
        cleanup(client, target)
    end
  end

  defp cleanup(client, target) do
    :gen_tcp.close(client)
    :gen_tcp.close(target)
    :ok
  end
end
