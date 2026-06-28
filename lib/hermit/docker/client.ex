defmodule Hermit.Docker.Client do
  @moduledoc """
  Mockable Network Namespace (netns) client for WireGuard and Tailscale.
  """
  require Logger

  @doc """
  Creates a WireGuard tunnel inside a local network namespace.
  """
  def create_wg_container(wg_name, storage_dir, _opts \\ []) do
    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        Logger.info("Mock: Creating WireGuard tunnel #{wg_name} with storage #{storage_dir}")
        {:ok, wg_name}

      true ->
        config_path = Path.join(storage_dir, "wg0.conf")
        Logger.info("Creating local netns: #{wg_name}")

        if netns_exists?(wg_name) do
          Logger.warning(
            "Stale network namespace found: #{wg_name}. Performing cleanup before recreation."
          )

          stop_pair(wg_name, "hermit_ts_#{id_from_name(wg_name)}")
        end

        id = id_from_name(wg_name)

        # Parse Address, DNS, and MTU from the config file
        config_content = File.read!(config_path)

        addresses =
          case Regex.run(~r/^\s*Address\s*=\s*([^\s#\n\r]+)/m, config_content) do
            [_, addrs] ->
              addrs
              |> String.split(",")
              |> Enum.map(&String.trim/1)

            _ ->
              []
          end

        dns_servers =
          case Regex.run(~r/^\s*DNS\s*=\s*([^\s#\n\r]+)/m, config_content) do
            [_, dns] ->
              dns
              |> String.split(",")
              |> Enum.map(&String.trim/1)

            _ ->
              []
          end

        mtu =
          case Regex.run(~r/^\s*MTU\s*=\s*(\d+)/m, config_content) do
            [_, mtu_val] -> mtu_val
            _ -> "1360"
          end

        # Create a unique temporary interface name on the host (max 15 chars)
        # using md5 hash of ID to prevent collisions on host
        unique_suffix =
          :crypto.hash(:md5, id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

        host_if_name = "wg_" <> unique_suffix

        # Create a stripped configuration for wg setconf
        stripped_content = strip_config(config_content)

        stripped_config_path = Path.join(storage_dir, "wg_stripped.conf")
        File.write!(stripped_config_path, stripped_content)

        # Build netns DNS directory configuration
        netns_dns_dir = "/etc/netns/#{wg_name}"

        # Execute network setup steps sequentially
        result =
          with {:ok, _} <- run_cmd("ip", ["netns", "add", wg_name]),
               {:ok, _} <- run_cmd("ip", ["link", "add", host_if_name, "type", "wireguard"]),
               {:ok, _} <- run_cmd("ip", ["link", "set", host_if_name, "netns", wg_name]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "link",
                   "set",
                   "dev",
                   host_if_name,
                   "name",
                   "wg0"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "link",
                   "set",
                   "mtu",
                   mtu,
                   "dev",
                   "wg0"
                 ]),
               {:addresses, :ok} <- {:addresses, add_addresses(wg_name, addresses)},
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "wg",
                   "setconf",
                   "wg0",
                   stripped_config_path
                 ]),
               {:ok, _} <-
                 run_cmd("ip", ["netns", "exec", wg_name, "ip", "link", "set", "lo", "up"]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "sysctl",
                   "-w",
                   "net.ipv4.ip_forward=1"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "sysctl",
                   "-w",
                   "net.ipv6.conf.all.forwarding=1"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "sysctl",
                   "-w",
                   "net.ipv4.udp_rmem_min=8192"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "sysctl",
                   "-w",
                   "net.ipv4.udp_wmem_min=8192"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", ["netns", "exec", wg_name, "ip", "link", "set", "wg0", "up"]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "route",
                   "add",
                   "default",
                   "dev",
                   "wg0"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "iptables",
                   "-t",
                   "mangle",
                   "-A",
                   "POSTROUTING",
                   "-p",
                   "tcp",
                   "--tcp-flags",
                   "SYN,RST",
                   "SYN",
                   "-j",
                   "TCPMSS",
                   "--clamp-mss-to-pmtu"
                 ]) do
            # Setup network namespace specific DNS
            if dns_servers != [] do
              File.mkdir_p!(netns_dns_dir)
              dns_lines = dns_servers |> Enum.map(&"nameserver #{&1}") |> Enum.join("\n")
              File.write!(Path.join(netns_dns_dir, "resolv.conf"), dns_lines)
            end

            # Apply UDP GRO forwarding optimizations (gracefully)
            case run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ethtool",
                   "-K",
                   "wg0",
                   "rx-udp-gro-forwarding",
                   "on",
                   "rx-gro-list",
                   "off"
                 ]) do
              {:ok, _} ->
                Logger.info(
                  "Successfully enabled UDP GRO forwarding on wg0 in namespace #{wg_name}"
                )

              {:error, reason} ->
                Logger.warning(
                  "Could not enable UDP GRO forwarding on wg0 in namespace #{wg_name}: #{inspect(reason)}. Continuing without GRO optimization."
                )
            end

            {:ok, wg_name}
          else
            {:error, reason} ->
              {:error, reason}

            {:addresses, {:error, reason}} ->
              {:error, reason}
          end

        # Rollback/cleanup on error
        case result do
          {:ok, _} ->
            {:ok, wg_name}

          {:error, reason} ->
            System.cmd("ip", ["link", "delete", host_if_name])
            System.cmd("ip", ["netns", "del", wg_name])
            File.rm_rf(netns_dns_dir)
            {:error, reason}
        end
    end
  end

  @doc """
  Starts a Tailscale daemon inside the WireGuard network namespace.
  """
  def create_ts_container(ts_name, wg_name, ts_auth_key, opts \\ []) do
    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        Logger.info("Mock: Starting Tailscale #{ts_name} in netns #{wg_name}")
        port = Port.open({:spawn, "cat"}, [:binary])
        {:ok, ts_name, port}

      true ->
        id = id_from_name(ts_name)
        state_dir = opts[:state_dir] || Path.join([get_storage_base_path(), id, "tailscale"])
        File.mkdir_p!(state_dir)

        socket_path = Path.join(state_dir, "tailscaled.socket")
        pid_path = Path.join(state_dir, "tailscaled.pid")
        state_path = Path.join(state_dir, "tailscaled.state")

        Logger.info("Starting tailscaled daemon in netns #{wg_name}")

        # Start tailscaled daemon in background inside the namespace
        port_args = [
          "netns",
          "exec",
          wg_name,
          "tailscaled",
          "--socket=#{socket_path}",
          "--state=#{state_path}",
          "--port=41641"
        ]

        try do
          # Port is owned by the calling process (PairWorker)
          port =
            Port.open({:spawn_executable, "/usr/bin/ip"}, [
              :binary,
              args: port_args
            ])

          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} ->
              File.write!(pid_path, "#{os_pid}")

            _ ->
              :ok
          end

          # Wait up to 2 seconds for socket creation
          wait_for_socket(socket_path)

          # Authenticate Tailscale and set exit node options
          ts_up_args = [
            "netns",
            "exec",
            wg_name,
            "tailscale",
            "--socket=#{socket_path}",
            "up",
            "--authkey=#{ts_auth_key}",
            "--advertise-exit-node",
            "--hostname=hermit-node-#{String.replace(id, "_", "-")}",
            "--timeout=30s"
          ]

          case run_cmd("ip", ts_up_args) do
            {:ok, _} ->
              {:ok, ts_name, port}

            {:error, reason} ->
              stop_tailscaled_by_pid(pid_path)
              {:error, {:tailscale_up_failed, reason}}
          end
        rescue
          e ->
            {:error, {:spawn_failed, e}}
        end
    end
  end

  @doc """
  Stops the Tailscale daemon and deletes the WireGuard network namespace.
  """
  def stop_pair(wg_name, _ts_name) do
    if mock?() do
      Logger.info("Mock: Stopping VPN pair with netns #{wg_name}")
      :ok
    else
      id = id_from_name(wg_name)
      storage_dir = Path.join(get_storage_base_path(), id)
      pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])

      Logger.info("Stopping VPN pair netns: #{wg_name}")

      # 1. Stop tailscaled daemon process
      stop_tailscaled_by_pid(pid_path)

      # 2. Delete the namespace
      if netns_exists?(wg_name) do
        System.cmd("ip", ["netns", "del", wg_name])
      end

      # 3. Clean up netns DNS config
      File.rm_rf("/etc/netns/#{wg_name}")

      :ok
    end
  end

  @doc """
  Checks status of the VPN pair namespace and tailscaled daemon.
  """
  def get_container_status(name) do
    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        id = id_from_name(name)
        storage_dir = Path.join(get_storage_base_path(), id)

        if File.exists?(storage_dir) do
          {:ok, %{status: "running", running: true}}
        else
          {:error, :not_found}
        end

      true ->
        id = id_from_name(name)
        wg_name = "hermit_wg_#{id}"
        storage_dir = Path.join(get_storage_base_path(), id)
        pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])

        cond do
          not netns_exists?(wg_name) ->
            {:error, :not_found}

          String.starts_with?(name, "hermit_wg_") ->
            {:ok, %{status: "running", running: true}}

          true ->
            running =
              case File.read(pid_path) do
                {:ok, pid_str} ->
                  pid = String.trim(pid_str)
                  File.exists?("/proc/#{pid}")

                _ ->
                  false
              end

            status = if running, do: "running", else: "exited"
            {:ok, %{status: status, running: running}}
        end
    end
  end

  @doc """
  Retrieves transfer metrics and Tailscale status info from inside namespace.
  """
  def get_network_info(wg_name) do
    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        id = id_from_name(wg_name)
        storage_dir = Path.join(get_storage_base_path(), id)

        if File.exists?(storage_dir) do
          {:ok,
           %{
             bytes_received: 1024,
             bytes_sent: 2048,
             ts_ips: ["100.64.0.5", "fd7a:115c:a1e0::5"],
             ts_backend_state: "Running",
             ts_user: "mock-user@example.com",
             ts_magic_dns: "hermit-node.mock-tailnet.ts.net",
             ts_exit_node: true,
             wg_port: 51820
           }}
        else
          {:error, :not_found}
        end

      true ->
        id = id_from_name(wg_name)
        storage_dir = Path.join(get_storage_base_path(), id)
        socket_path = Path.join([storage_dir, "tailscale", "tailscaled.socket"])

        ts_info =
          if File.exists?(socket_path) do
            case System.cmd(
                   "ip",
                   [
                     "netns",
                     "exec",
                     wg_name,
                     "tailscale",
                     "--socket=#{socket_path}",
                     "status",
                     "--json"
                   ],
                   stderr_to_stdout: true
                 ) do
              {output, 0} ->
                case Jason.decode(output) do
                  {:ok, data} ->
                    self_node = Map.get(data, "Self", %{})
                    ips = Map.get(self_node, "TailscaleIPs", [])
                    backend_state = Map.get(data, "BackendState", "Unknown")

                    user_id = Map.get(self_node, "UserID", 0)
                    users = Map.get(data, "User", %{})
                    user_info = Map.get(users, to_string(user_id), %{})
                    user_login = Map.get(user_info, "LoginName", "Unknown")

                    dns_name = Map.get(self_node, "DNSName", "")
                    exit_node = Map.get(self_node, "ExitNode", false)

                    %{
                      ts_ips: ips,
                      ts_backend_state: backend_state,
                      ts_user: user_login,
                      ts_magic_dns: dns_name,
                      ts_exit_node: exit_node
                    }

                  _ ->
                    nil
                end

              _ ->
                nil
            end
          else
            nil
          end

        pid_path = Path.join([storage_dir, "tailscale", "tailscaled.pid"])

        pid =
          case File.read(pid_path) do
            {:ok, pid_str} -> String.trim(pid_str)
            _ -> nil
          end

        ts_defaults = %{
          ts_ips: [],
          ts_backend_state: "Offline",
          ts_user: "Unknown",
          ts_magic_dns: "",
          ts_exit_node: false,
          wg_port: nil
        }

        ts_data =
          (ts_info || ts_defaults)
          |> Map.put(:wg_port, get_wg_listen_port(wg_name))

        metrics =
          if pid do
            with {:ok, content} <- File.read("/proc/#{pid}/net/dev"),
                 parsed when not is_nil(parsed) <- parse_proc_net_dev(content, "wg0") do
              {:ok, Map.merge(parsed, ts_data)}
            else
              _ -> :error
            end
          else
            :error
          end

        case metrics do
          {:ok, data} ->
            {:ok, data}

          :error ->
            # Fallback to system command (more expensive but always works on Linux with netns)
            case System.cmd("ip", ["netns", "exec", wg_name, "wg", "show", "wg0", "transfer"],
                   stderr_to_stdout: true
                 ) do
              {output, 0} ->
                data =
                  output
                  |> parse_wg_transfer()
                  |> Map.merge(ts_data)

                {:ok, data}

              _ ->
                {:error, :not_found}
            end
        end
    end
  end

  defp parse_proc_net_dev(content, interface) do
    target = "#{interface}:"

    line =
      content
      |> String.split("\n")
      |> Enum.find(fn l -> String.contains?(l, target) end)

    case line do
      nil ->
        nil

      l ->
        clean_line = String.replace(l, target, "")

        case String.split(clean_line, " ", trim: true) do
          [
            rx_bytes,
            _rx_pkts,
            _rx_errs,
            _rx_drop,
            _rx_fifo,
            _rx_frame,
            _rx_comp,
            _rx_multi,
            tx_bytes | _
          ] ->
            case {Integer.parse(rx_bytes), Integer.parse(tx_bytes)} do
              {{rx, ""}, {tx, ""}} ->
                %{bytes_received: rx, bytes_sent: tx}

              _ ->
                nil
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  @doc """
  Approves advertised exit node routes for a Tailscale node using Tailscale API.
  """
  def approve_exit_node(id) do
    cond do
      mock?() ->
        Logger.info("Mock: Approving Tailscale exit node for #{id}")
        {:ok, :approved}

      true ->
        api_key = Hermit.Vpn.Setting.get_value("tailscale_api_key", "")
        tailnet = Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

        if api_key == "" or tailnet == "" do
          Logger.warning(
            "Tailscale API credentials not configured. Skipping auto-approval of exit node."
          )

          {:error, :missing_credentials}
        else
          # Hostname advertised by this node
          expected_hostname = "hermit-node-#{String.replace(id, "_", "-")}"
          Logger.info("Starting Tailscale exit node approval for #{expected_hostname}")

          # Retry up to 5 times to let the device register
          do_approve_exit_node(api_key, tailnet, expected_hostname, 5)
        end
    end
  end

  defp do_approve_exit_node(_api_key, _tailnet, expected_hostname, 0) do
    Logger.error("Failed to find Tailscale device #{expected_hostname} after multiple retries.")
    {:error, :device_not_found}
  end

  defp do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left) do
    # 1. Fetch devices list
    devices_url = "https://api.tailscale.com/api/v2/tailnet/#{tailnet}/devices"

    case Req.get(devices_url, auth: {:basic, "#{api_key}:"}) do
      {:ok, %{status: 200, body: %{"devices" => devices}}} ->
        # Find device matching hostname or name prefix
        device =
          Enum.find(devices, fn dev ->
            dev["hostname"] == expected_hostname or
              String.starts_with?(dev["name"] || "", expected_hostname <> ".")
          end)

        if device do
          device_id = device["id"]

          Logger.info(
            "Found Tailscale device #{expected_hostname} with ID #{device_id}. Approving routes..."
          )

          # 2. Approve 0.0.0.0/0 and ::/0 exit node routes
          routes_url = "https://api.tailscale.com/api/v2/device/#{device_id}/routes"
          routes_payload = %{routes: ["0.0.0.0/0", "::/0"]}

          case Req.post(routes_url, json: routes_payload, auth: {:basic, "#{api_key}:"}) do
            {:ok, %{status: 200}} ->
              Logger.info("Successfully approved exit node routes for #{expected_hostname}")
              {:ok, :approved}

            {:ok, %{status: status, body: body}} ->
              Logger.error(
                "Failed to approve Tailscale routes (HTTP #{status}): #{inspect(body)}"
              )

              {:error, {:routes_api_failed, status, body}}

            {:error, reason} ->
              Logger.error("Failed to call Tailscale routes API: #{inspect(reason)}")
              {:error, reason}
          end
        else
          Logger.info(
            "Tailscale device #{expected_hostname} not registered yet. Retrying in 3 seconds... (#{retries_left - 1} left)"
          )

          Process.sleep(3000)
          do_approve_exit_node(api_key, tailnet, expected_hostname, retries_left - 1)
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to fetch Tailscale devices (HTTP #{status}): #{inspect(body)}")
        {:error, {:devices_api_failed, status, body}}

      {:error, reason} ->
        Logger.error("Failed to call Tailscale devices API: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Internal Helpers ---

  @doc false
  def strip_config(config_content) when is_binary(config_content) do
    config_content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line) |> String.downcase()

      String.starts_with?(trimmed, "address") or
        String.starts_with?(trimmed, "dns") or
        String.starts_with?(trimmed, "mtu") or
        String.starts_with?(trimmed, "listenport")
    end)
    |> Enum.join("\n")
  end

  defp get_wg_listen_port(wg_name) do
    case System.cmd("ip", ["netns", "exec", wg_name, "wg", "show", "wg0", "listen-port"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {port, ""} -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  defp get_mock_error do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock_error)
  end

  defp get_storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
  end

  defp id_from_name(name) do
    name
    |> String.replace("hermit_wg_", "")
    |> String.replace("hermit_ts_", "")
  end

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"]) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          String.starts_with?(line, ns_name)
        end)

      _ ->
        false
    end
  end

  defp stop_tailscaled_by_pid(pid_path) do
    if File.exists?(pid_path) do
      case File.read(pid_path) do
        {:ok, pid_str} ->
          pid = String.trim(pid_str)
          Logger.info("Killing tailscaled process: #{pid}")
          System.cmd("kill", [pid])
          Process.sleep(200)
          # Force kill if still running
          System.cmd("kill", ["-9", pid])

        _ ->
          :ok
      end
    end
  end

  defp add_addresses(wg_name, addresses) do
    Enum.reduce_while(addresses, :ok, fn addr, :ok ->
      case run_cmd("ip", ["netns", "exec", wg_name, "ip", "address", "add", addr, "dev", "wg0"]) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_cmd(cmd, args) do
    Logger.info("Running: #{cmd} #{Enum.join(args, " ")}")

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error(
          "Command failed: #{cmd} #{Enum.join(args, " ")} (exit code #{code}): #{output}"
        )

        {:error, {code, String.trim(output)}}
    end
  end

  defp wait_for_socket(path, retries \\ 10)
  defp wait_for_socket(_path, 0), do: :ok

  defp wait_for_socket(path, retries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(200)
      wait_for_socket(path, retries - 1)
    end
  end

  defp parse_wg_transfer(output) when is_binary(output) do
    case String.split(output) do
      [_interface, rx, tx | _] ->
        {rx_int, ""} = Integer.parse(rx)
        {tx_int, ""} = Integer.parse(tx)
        %{bytes_received: rx_int, bytes_sent: tx_int}

      _ ->
        %{bytes_received: 0, bytes_sent: 0}
    end
  rescue
    _ -> %{bytes_received: 0, bytes_sent: 0}
  end

  defp parse_wg_transfer(_), do: %{bytes_received: 0, bytes_sent: 0}
end
