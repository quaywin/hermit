defmodule Hermit.Dns.Port53Server do
  @moduledoc """
  Standalone UDP/TCP server process listening on Port 53 (0.0.0.0:53).
  Matches incoming home router queries by source IP to DDNS Endpoints,
  then delegates resolution directly to the endpoint's dedicated Hermit.Dns.Server process.
  """
  use GenServer
  import Bitwise
  alias Hermit.Dns.Packet
  alias Hermit.Vpn.DnsDdnsResolver
  require Logger

  @port 53

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    port = Application.get_env(:hermit, :port53_port, @port)

    state = %{
      udp_socket: nil,
      tcp_socket: nil,
      port: port
    }

    case try_bind_port53(state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, _reason, new_state} ->
        # Retry binding port periodically in case port becomes free
        Process.send_after(self(), :retry_bind, 5000)
        {:ok, new_state}
    end
  end

  @impl true
  def handle_info(:retry_bind, state) do
    if is_nil(state.udp_socket) do
      case try_bind_port53(state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, _reason, new_state} ->
          Process.send_after(self(), :retry_bind, 5000)
          {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{udp_socket: socket} = state) do
    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
      client_ip_str = :inet.ntoa(ip) |> to_string()

      case DnsDdnsResolver.lookup_endpoint(client_ip_str) do
        nil ->
          process_fallback_udp_query(socket, ip, port, packet, client_ip_str)

        endpoint_id ->
          process_ddns_query(socket, ip, port, packet, endpoint_id, client_ip_str)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal Helpers ---

  defp try_bind_port53(state) do
    port = state.port
    {udp_ip, family_opts} = resolve_udp_bind_ip()
    udp_opts = [:binary, active: 1000, reuseaddr: true, recbuf: 1024 * 1024, ip: udp_ip] ++ family_opts
    tcp_opts = [:binary, packet: 2, active: false, reuseaddr: true]

    case :gen_udp.open(port, udp_opts) do
      {:ok, udp_socket} ->
        tcp_socket =
          case :gen_tcp.listen(port, tcp_opts) do
            {:ok, t_sock} ->
              server_pid = self()
              spawn_link(fn -> tcp_accept_loop(t_sock, server_pid) end)
              t_sock

            {:error, reason} ->
              Logger.info("Port #{port} TCP is occupied (#{inspect(reason)}). UDP listener remains active.")
              nil
          end

        Logger.info("Hermit Standalone Port 53 Server successfully listening on UDP/TCP port #{port} (UDP IP: #{:inet.ntoa(udp_ip) |> to_string()})")
        {:ok, %{state | udp_socket: udp_socket, tcp_socket: tcp_socket, port: port}}

      {:error, reason} ->
        Logger.info("Port #{port} UDP is occupied (#{inspect(reason)}). Standalone Port 53 server will retry.")
        {:error, reason, state}
    end
  end

  defp resolve_udp_bind_ip do
    case :inet.gethostbyname(~c"fly-global-services", :inet) do
      {:ok, {:hostent, _, _, :inet, 4, [ip_tuple | _]}} ->
        Logger.info("Port53 Server: Binding UDP socket to Fly.io global services IPv4 #{:inet.ntoa(ip_tuple) |> to_string()}")
        {ip_tuple, []}

      _ ->
        case :inet.gethostbyname(~c"fly-global-services", :inet6) do
          {:ok, {:hostent, _, _, :inet6, 16, [ip_tuple | _]}} ->
            Logger.info("Port53 Server: Binding UDP socket to Fly.io global services IPv6 #{inspect(ip_tuple)}")
            {ip_tuple, [:inet6]}

          _ ->
            {{0, 0, 0, 0}, []}
        end
    end
  end

  defp tcp_accept_loop(tcp_socket, server_pid) do
    case :gen_tcp.accept(tcp_socket) do
      {:ok, client_socket} ->
        spawn(fn -> handle_tcp_client(client_socket) end)
        tcp_accept_loop(tcp_socket, server_pid)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        tcp_accept_loop(tcp_socket, server_pid)
    end
  end

  defp handle_tcp_client(client_socket) do
    case :inet.peername(client_socket) do
      {:ok, {ip, _port}} ->
        client_ip_str = :inet.ntoa(ip) |> to_string()

        case :gen_tcp.recv(client_socket, 0, 5000) do
          {:ok, packet} ->
            case DnsDdnsResolver.lookup_endpoint(client_ip_str) do
              nil ->
                process_fallback_tcp_query(client_socket, packet, client_ip_str, ip)

              endpoint_id ->
                case resolve_via_endpoint_dns_server(endpoint_id, packet, ip) do
                  {:ok, response_packet} ->
                    :gen_tcp.send(client_socket, response_packet)

                  {:servfail, servfail_packet} ->
                    :gen_tcp.send(client_socket, servfail_packet)

                  {:error, _reason} ->
                    send_tcp_error(client_socket, packet, 2)
                end
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :gen_tcp.close(client_socket)
  end

  defp process_ddns_query(socket, ip, port, packet, endpoint_id, _client_ip_str) do
    case resolve_via_endpoint_dns_server(endpoint_id, packet, ip) do
      {:ok, response_packet} ->
        :gen_udp.send(socket, ip, port, response_packet)

      {:servfail, servfail_packet} ->
        :gen_udp.send(socket, ip, port, servfail_packet)

      {:error, _reason} ->
        send_udp_error(socket, ip, port, packet, 2)
    end
  end

  @doc false
  def resolve_via_endpoint_dns_server(endpoint_id, packet, client_ip) do
    case get_or_start_dns_server(endpoint_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:resolve_query, packet, client_ip}, 4000)
        catch
          :exit, {:timeout, _} ->
            Logger.error("Port53 Server: DNS query timed out for endpoint: #{endpoint_id}")
            {:servfail, build_servfail_packet(packet)}

          :exit, reason ->
            Logger.error("Port53 Server: DNS Server call exited for endpoint #{endpoint_id}: #{inspect(reason)}")
            {:servfail, build_servfail_packet(packet)}
        end

      :error ->
        {:servfail, build_servfail_packet(packet)}
    end
  end

  defp get_or_start_dns_server(endpoint_id) do
    case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, endpoint_id) do
          nil ->
            :error

          endpoint ->
            case Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, endpoint.inbound_profile_id) do
              {:ok, {_worker, server_pid}} when is_pid(server_pid) ->
                {:ok, server_pid}

              {:ok, server_pid} when is_pid(server_pid) ->
                {:ok, server_pid}

              {:error, {:already_started, pid}} ->
                {:ok, pid}

              _ ->
                case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
                  [{pid, _}] -> {:ok, pid}
                  [] -> :error
                end
            end
        end
    end
  end

  defp build_servfail_packet(query_packet) do
    case Packet.parse(query_packet) do
      {:ok, query} ->
        servfail = Packet.build_nxdomain(query.id, query.query_record)
        Packet.patch_rcode(servfail, 2)

      _ ->
        if byte_size(query_packet) >= 12 do
          <<id::binary-size(2), _::binary>> = query_packet
          <<id::binary, 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
        else
          <<0x00, 0x00, 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
        end
    end
  end

  defp process_fallback_udp_query(socket, ip, port, packet, client_ip_str) do
    case Packet.parse(packet) do
      {:ok, query} ->
        Logger.info("Port53 Server: Query '#{query.domain}' from #{client_ip_str} -> FALLBACK (Resolved via 1.1.1.1)")
        forward_fallback_udp(socket, ip, port, packet)
        emit_fallback_telemetry(ip, query, "fallback", "Resolved via 1.1.1.1", "1.1.1.1 (Fallback)")

      _ ->
        send_udp_error(socket, ip, port, packet, 2)
    end
  end

  defp process_fallback_tcp_query(client_socket, packet, client_ip_str, ip) do
    case Packet.parse(packet) do
      {:ok, query} ->
        Logger.info("Port53 Server (TCP): Query '#{query.domain}' from #{client_ip_str} -> FALLBACK (Resolved via 1.1.1.1)")
        forward_fallback_tcp(client_socket, packet)
        emit_fallback_telemetry(ip, query, "fallback", "Resolved via 1.1.1.1", "1.1.1.1 (Fallback)")

      _ ->
        send_tcp_error(client_socket, packet, 2)
    end
  end

  defp forward_fallback_udp(socket, client_ip, client_port, packet) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, upstream_socket} ->
        :gen_udp.send(upstream_socket, {1, 1, 1, 1}, 53, packet)

        case :gen_udp.recv(upstream_socket, 0, 2000) do
          {:ok, {_u_ip, _u_port, response_packet}} ->
            :gen_udp.send(socket, client_ip, client_port, response_packet)

          _ ->
            send_udp_error(socket, client_ip, client_port, packet, 2)
        end

        :gen_udp.close(upstream_socket)

      _ ->
        send_udp_error(socket, client_ip, client_port, packet, 2)
    end
  end

  defp forward_fallback_tcp(client_socket, packet) do
    case :gen_tcp.connect({1, 1, 1, 1}, 53, [:binary, packet: 2, active: false], 2000) do
      {:ok, u_sock} ->
        :gen_tcp.send(u_sock, packet)

        case :gen_tcp.recv(u_sock, 0, 2000) do
          {:ok, response_packet} ->
            :gen_tcp.send(client_socket, response_packet)

          _ ->
            send_tcp_error(client_socket, packet, 2)
        end

        :gen_tcp.close(u_sock)

      _ ->
        send_tcp_error(client_socket, packet, 2)
    end
  end

  defp emit_fallback_telemetry(ip, query, status, answer, resolver) do
    :telemetry.execute(
      [:hermit, :dns, :query],
      %{duration: 1000},
      %{
        profile_id: nil,
        config_id: nil,
        client_ip: ip,
        domain: query.domain,
        qtype: query.qtype,
        status: status,
        answer: answer,
        resolver: resolver,
        enable_query_logging: true,
        endpoint_name: "Port 53 Fallback"
      }
    )
  end

  # rcode: 5 = REFUSED, 2 = SERVFAIL
  defp build_dns_error(packet, rcode) do
    if byte_size(packet) >= 12 do
      <<id::binary-size(2), _flags::binary-size(2), rest::binary>> = packet
      flag_byte2 = 0x80 ||| (rcode &&& 0x0F)
      id <> <<0x81, flag_byte2>> <> rest
    else
      nil
    end
  end

  defp send_udp_error(socket, ip, port, packet, rcode) do
    case build_dns_error(packet, rcode) do
      nil -> :ok
      resp -> :gen_udp.send(socket, ip, port, resp)
    end
  end

  defp send_tcp_error(client_socket, packet, rcode) do
    case build_dns_error(packet, rcode) do
      nil -> :ok
      resp -> :gen_tcp.send(client_socket, resp)
    end
  end
end
