defmodule Hermit.Vpn.Inbound.Proxy.Relayer do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    pair_id = opts[:pair_id]
    storage_dir = opts[:storage_dir]
    wg_name = "hermit_wg_#{pair_id}"
    proxy_port = opts[:port] || 0
    octet = :erlang.phash2(pair_id, 255)

    unique_suffix =
      :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 10)

    vh_name = "vh_#{unique_suffix}"
    vn_name = "vn_#{unique_suffix}"

    host_ip = "172.29.#{octet}.1"
    ns_ip = "172.29.#{octet}.2"

    socks_port = 1080
    http_port = 8080

    mock? = mock?()

    result =
      if mock? do
        {:ok, :mocked}
      else
        with :ok <- setup_veth(wg_name, vh_name, vn_name, host_ip, ns_ip),
             :ok <- write_tinyproxy_config(storage_dir, ns_ip, http_port),
             {:ok, socks_port_proc} <- start_microsocks(wg_name, ns_ip, socks_port),
             {:ok, http_port_proc} <- start_tinyproxy(wg_name, storage_dir) do
          # Write proxy pids to files so cleanup can access them if needed
          write_pid_file(storage_dir, "microsocks.pid", socks_port_proc)
          write_pid_file(storage_dir, "tinyproxy.pid", http_port_proc)
          {:ok, {socks_port_proc, http_port_proc}}
        else
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      {:ok, procs} ->
        # Start TCP listener on the host
        # If proxy_port is 0 or nil, it will listen on an ephemeral port assigned by the OS
        listen_port =
          case proxy_port do
            nil -> 0
            "" -> 0
            p when is_binary(p) -> String.to_integer(p)
            p -> p
          end

        case :gen_tcp.listen(listen_port, [
               :binary,
               packet: :raw,
               active: false,
               reuseaddr: true,
               nodelay: true,
               recbuf: 262_144,
               sndbuf: 262_144,
               buffer: 262_144,
               send_timeout: 5000,
               send_timeout_close: true
             ]) do
          {:ok, listen_socket} ->
            {:ok, actual_port} = :inet.port(listen_socket)
            Logger.info("Host Proxy Relayer listening on port #{actual_port}")

            # Write proxy connection info to JSON file
            info = %{
              "port" => actual_port,
              "socks5_url" => "socks5://127.0.0.1:#{actual_port}",
              "http_url" => "http://127.0.0.1:#{actual_port}",
              "status" => "Running"
            }

            File.write!(Path.join(storage_dir, "proxy_info.json"), Jason.encode!(info))
            # Also write main pid file for get_status
            File.write!(Path.join(storage_dir, "proxy.pid"), "#{System.pid()}")

            state = %{
              pair_id: pair_id,
              storage_dir: storage_dir,
              vh_name: vh_name,
              listen_socket: listen_socket,
              socks_port_proc: if(procs == :mocked, do: nil, else: elem(procs, 0)),
              http_port_proc: if(procs == :mocked, do: nil, else: elem(procs, 1)),
              ns_ip: ns_ip,
              socks_port: socks_port,
              http_port: http_port,
              actual_port: actual_port,
              mock?: mock?
            }

            send(self(), :accept)
            {:ok, state}

          {:error, reason} ->
            unless mock?, do: cleanup_veth(vh_name)
            {:stop, {:listen_failed, reason}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 1000) do
      {:ok, client_socket} ->
        # Spawn client handler to relay traffic
        pid =
          spawn_link(fn ->
            # Limit the process heap memory to 100MB (13,107,200 words on 64-bit systems) to prevent OOM
            Process.flag(:max_heap_size, %{size: 13_107_200, kill: true, error_logger: true})

            receive do
              :start ->
                relay_connection(
                  client_socket,
                  state.ns_ip,
                  state.socks_port,
                  state.http_port,
                  state.mock?
                )
            end
          end)

        case :gen_tcp.controlling_process(client_socket, pid) do
          :ok ->
            send(pid, :start)

          {:error, reason} ->
            Logger.error("Failed to set controlling process: #{inspect(reason)}")
            :gen_tcp.close(client_socket)
        end

        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("TCP Accept error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  # Monitor child ports
  @impl true
  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    cond do
      port == state.socks_port_proc ->
        Logger.error("microsocks daemon exited: #{inspect(reason)}")
        {:stop, {:microsocks_exited, reason}, state}

      port == state.http_port_proc ->
        Logger.error("tinyproxy daemon exited: #{inspect(reason)}")
        {:stop, {:tinyproxy_exited, reason}, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Stopping Proxy Relayer for #{state.pair_id}: #{inspect(reason)}")

    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    # Kill microsocks and tinyproxy inside the netns
    unless state.mock? do
      kill_port_process(state.socks_port_proc)
      kill_port_process(state.http_port_proc)
      cleanup_veth(state.vh_name)
    end

    # Delete local files
    File.rm(Path.join(state.storage_dir, "proxy_info.json"))
    File.rm(Path.join(state.storage_dir, "proxy.pid"))
    File.rm(Path.join(state.storage_dir, "microsocks.pid"))
    File.rm(Path.join(state.storage_dir, "tinyproxy.pid"))
    File.rm(Path.join(state.storage_dir, "tinyproxy.conf"))

    :ok
  end

  # --- Connection Relaying Logic ---

  defp relay_connection(client_socket, ns_ip, socks_port, http_port, mock?) do
    # Read the first packet from the client (up to 15s timeout)
    case :gen_tcp.recv(client_socket, 0, 15000) do
      {:ok, packet} ->
        if mock? do
          # Mock mode handling
          case packet do
            <<0x05, _num_methods, _methods::binary>> ->
              :gen_tcp.send(client_socket, <<0x05, 0x00>>)

              case :gen_tcp.recv(client_socket, 0, 5000) do
                {:ok, _req} ->
                  # Success response
                  :gen_tcp.send(
                    client_socket,
                    <<0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0>>
                  )

                  mock_echo_loop(client_socket)

                _ ->
                  :ok
              end

            _ ->
              :gen_tcp.send(
                client_socket,
                "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nMock Proxy"
              )

              :gen_tcp.close(client_socket)
          end
        else
          # Detect protocol by checking the first byte
          # SOCKS5 = 0x05, SOCKS4 = 0x04. Otherwise HTTP.
          case packet do
            <<first_byte, _rest::binary>> ->
              dest_port = if first_byte in [0x04, 0x05], do: socks_port, else: http_port

              case :gen_tcp.connect(String.to_charlist(ns_ip), dest_port, [
                     :binary,
                     packet: :raw,
                     active: false,
                     nodelay: true,
                     recbuf: 262_144,
                     sndbuf: 262_144,
                     buffer: 262_144,
                     send_timeout: 5000,
                     send_timeout_close: true
                   ]) do
                {:ok, dest_socket} ->
                  # Forward the first packet to the namespace proxy daemon
                  case :gen_tcp.send(dest_socket, packet) do
                    :ok ->
                      # Set both to active: 400 to stream data with flow control/backpressure
                      :inet.setopts(client_socket, active: 400)
                      :inet.setopts(dest_socket, active: 400)
                      active_relay_loop(client_socket, dest_socket)

                    {:error, _} ->
                      :gen_tcp.close(client_socket)
                      :gen_tcp.close(dest_socket)
                  end

                {:error, reason} ->
                  Logger.error(
                    "Proxy Relayer failed to connect to namespace daemon on port #{dest_port}: #{inspect(reason)}"
                  )

                  :gen_tcp.close(client_socket)
              end

            _ ->
              :gen_tcp.close(client_socket)
          end
        end

      {:error, _} ->
        :gen_tcp.close(client_socket)
    end
  end

  defp active_relay_loop(s1, s2) do
    receive do
      {:tcp, ^s1, data} ->
        case :gen_tcp.send(s2, data) do
          :ok -> active_relay_loop(s1, s2)
          {:error, _} -> close_sockets(s1, s2)
        end

      {:tcp, ^s2, data} ->
        case :gen_tcp.send(s1, data) do
          :ok -> active_relay_loop(s1, s2)
          {:error, _} -> close_sockets(s1, s2)
        end

      {:tcp_passive, ^s1} ->
        :inet.setopts(s1, active: 400)
        active_relay_loop(s1, s2)

      {:tcp_passive, ^s2} ->
        :inet.setopts(s2, active: 400)
        active_relay_loop(s1, s2)

      {:tcp_closed, _socket} ->
        close_sockets(s1, s2)

      {:tcp_error, _socket, _reason} ->
        close_sockets(s1, s2)
    after
      60000 ->
        # 60s idle timeout
        close_sockets(s1, s2)
    end
  end

  defp close_sockets(s1, s2) do
    :gen_tcp.close(s1)
    :gen_tcp.close(s2)
  end

  defp mock_echo_loop(socket) do
    :inet.setopts(socket, active: true)

    receive do
      {:tcp, ^socket, data} ->
        :gen_tcp.send(socket, data)
        mock_echo_loop(socket)

      {:tcp_closed, _socket} ->
        :ok
    after
      10000 -> :gen_tcp.close(socket)
    end
  end

  # --- Linux Networking and Daemons Setup ---

  defp setup_veth(wg_name, vh_name, vn_name, host_ip, ns_ip) do
    Logger.info("Setting up veth interfaces: #{vh_name} <-> #{vn_name} for #{wg_name}")

    with {:ok, _} <-
           run_cmd("ip", ["link", "add", vh_name, "type", "veth", "peer", "name", vn_name]),
         {:ok, _} <- run_cmd("ip", ["link", "set", vn_name, "netns", wg_name]),
         {:ok, _} <- run_cmd("ip", ["addr", "add", "#{host_ip}/30", "dev", vh_name]),
         {:ok, _} <- run_cmd("ip", ["link", "set", vh_name, "up"]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             wg_name,
             "ip",
             "addr",
             "add",
             "#{ns_ip}/30",
             "dev",
             vn_name
           ]),
         {:ok, _} <-
           run_cmd("ip", ["netns", "exec", wg_name, "ip", "link", "set", vn_name, "up"]) do
      :ok
    else
      {:error, reason} -> {:error, {:veth_setup_failed, reason}}
    end
  end

  defp cleanup_veth(vh_name) do
    Logger.info("Cleaning up veth interface: #{vh_name}")
    System.cmd("ip", ["link", "delete", vh_name])
    :ok
  end

  defp write_tinyproxy_config(storage_dir, listen_ip, port) do
    conf_path = Path.join(storage_dir, "tinyproxy.conf")
    pid_path = Path.join(storage_dir, "tinyproxy.pid")
    log_path = Path.join(storage_dir, "tinyproxy.log")

    content = """
    Port #{port}
    Listen #{listen_ip}
    Timeout 600
    MaxClients 100
    MinSpareServers 2
    MaxSpareServers 10
    StartServers 5
    MaxRequestsPerChild 0
    Allow 172.29.0.0/16
    Allow 127.0.0.1
    PidFile "#{pid_path}"
    LogFile "#{log_path}"
    LogLevel Info
    """

    File.write!(conf_path, content)
    :ok
  end

  defp start_microsocks(wg_name, ns_ip, port) do
    Logger.info("Starting microsocks inside netns #{wg_name} on #{ns_ip}:#{port}")

    port_args = [
      "netns",
      "exec",
      wg_name,
      "microsocks",
      "-p",
      "#{port}",
      "-i",
      ns_ip
    ]

    try do
      p = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: port_args])
      {:ok, p}
    rescue
      e -> {:error, {:microsocks_spawn_failed, e}}
    end
  end

  defp start_tinyproxy(wg_name, storage_dir) do
    conf_path = Path.join(storage_dir, "tinyproxy.conf")
    Logger.info("Starting tinyproxy inside netns #{wg_name} using config #{conf_path}")

    port_args = [
      "netns",
      "exec",
      wg_name,
      "tinyproxy",
      "-d",
      "-c",
      conf_path
    ]

    try do
      p = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: port_args])
      {:ok, p}
    rescue
      e -> {:error, {:tinyproxy_spawn_failed, e}}
    end
  end

  defp write_pid_file(storage_dir, filename, port) do
    path = Path.join(storage_dir, filename)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        File.write!(path, "#{os_pid}")

      _ ->
        :ok
    end
  end

  defp kill_port_process(nil), do: :ok

  defp kill_port_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Logger.info("Killing process #{os_pid}")
        System.cmd("kill", ["#{os_pid}"])
        Process.sleep(100)
        System.cmd("kill", ["-9", "#{os_pid}"])
        Port.close(port)

      _ ->
        :ok
    end
  end

  # --- General Helpers ---

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, :ok}
      {output, code} -> {:error, {code, String.trim(output)}}
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
