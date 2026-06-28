defmodule Hermit.Vpn.Outbound.WireGuard do
  @behaviour Hermit.Vpn.Outbound
  require Logger

  @impl true
  def bootstrap(pair_id, storage_dir, config) do
    wg_name = "hermit_wg_#{pair_id}"
    config_path = Path.join(storage_dir, "wg0.conf")

    config_content =
      if File.exists?(config_path) do
        File.read!(config_path)
      else
        Map.get(config, :wg_config) || Map.get(config, "wg_config") || ""
      end

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        Logger.info("Mock: Creating WireGuard tunnel #{wg_name} with storage #{storage_dir}")
        {:ok, "wg0"}

      true ->
        Logger.info("Creating local netns: #{wg_name}")

        if netns_exists?(wg_name) do
          Logger.warning(
            "Stale network namespace found: #{wg_name}. Performing cleanup before recreation."
          )

          cleanup(pair_id, storage_dir)
        end

        # Parse Address, DNS, and MTU from the config file
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
          :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

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

            {:ok, "wg0"}
          else
            {:error, reason} ->
              {:error, reason}

            {:addresses, {:error, reason}} ->
              {:error, reason}
          end

        # Rollback/cleanup on error
        case result do
          {:ok, _} ->
            {:ok, "wg0"}

          {:error, reason} ->
            System.cmd("ip", ["link", "delete", host_if_name])
            System.cmd("ip", ["netns", "del", wg_name])
            File.rm_rf(netns_dns_dir)
            {:error, reason}
        end
    end
  end

  @impl true
  def cleanup(pair_id, _storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Stopping VPN pair with netns #{wg_name}")
      :ok
    else
      # Unique suffix based on pair_id md5 hash to delete the host interface
      unique_suffix =
        :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

      host_if_name = "wg_" <> unique_suffix

      Logger.info("Stopping WireGuard netns: #{wg_name}")

      # Delete host interface if any
      System.cmd("ip", ["link", "delete", host_if_name])

      # Delete the namespace
      if netns_exists?(wg_name) do
        System.cmd("ip", ["netns", "del", wg_name])
      end

      # Clean up netns DNS config
      File.rm_rf("/etc/netns/#{wg_name}")

      :ok
    end
  end

  @impl true
  def get_status(pair_id, _storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        # For mock, check if directory exists
        storage_dir = Path.join(get_storage_base_path(), pair_id)

        if File.exists?(storage_dir) do
          :running
        else
          :stopped
        end

      true ->
        if netns_exists?(wg_name) do
          :running
        else
          :stopped
        end
    end
  end

  @impl true
  def get_metrics(pair_id, storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      err = get_mock_error() ->
        {:error, err}

      mock?() ->
        if File.exists?(storage_dir) do
          {:ok, %{bytes_received: 1024, bytes_sent: 2048}}
        else
          {:error, :not_found}
        end

      true ->
        # We need a process PID running inside the netns to read /proc/<pid>/net/dev.
        # We check possible PID files written by Inbound modules.
        pid =
          ["tailscale/tailscaled.pid", "microsocks.pid", "tinyproxy.pid"]
          |> Enum.find_value(fn rel_path ->
            path = Path.join(storage_dir, rel_path)

            case File.read(path) do
              {:ok, content} ->
                cleaned = String.trim(content)

                if cleaned != "" and cleaned != "#{System.pid()}" do
                  cleaned
                else
                  nil
                end

              _ ->
                nil
            end
          end)

        metrics =
          if pid do
            with {:ok, content} <- File.read("/proc/#{pid}/net/dev"),
                 interfaces = parse_net_dev(content),
                 extracted = extract_metrics(interfaces) do
              {:ok, extracted}
            else
              _ -> :error
            end
          else
            :error
          end

        case metrics do
          {:ok, data} ->
            # Read wg port from the netns too
            wg_port = get_wg_listen_port(wg_name)
            {:ok, Map.put(data, :wg_port, wg_port)}

          :error ->
            # Fallback to system command (more expensive but always works on Linux with netns)
            # Try reading /proc/net/dev from netns first so we can parse tailscale0 if present
            case System.cmd("ip", ["netns", "exec", wg_name, "cat", "/proc/net/dev"],
                   stderr_to_stdout: true
                 ) do
              {output, 0} ->
                interfaces = parse_net_dev(output)
                data = extract_metrics(interfaces)
                wg_port = get_wg_listen_port(wg_name)
                {:ok, Map.put(data, :wg_port, wg_port)}

              _ ->
                # Last resort fallback to wg show transfer
                case System.cmd("ip", ["netns", "exec", wg_name, "wg", "show", "wg0", "transfer"],
                       stderr_to_stdout: true
                     ) do
                  {output, 0} ->
                    data = parse_wg_transfer(output)
                    wg_port = get_wg_listen_port(wg_name)
                    {:ok, Map.put(data, :wg_port, wg_port)}

                  _ ->
                    :error
                end
            end
        end
    end
  end

  # --- Internal Helpers ---

  defp parse_net_dev(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      if String.contains?(line, ":") do
        [iface, stats_str] = String.split(line, ":", parts: 2)
        iface = String.trim(iface)

        case String.split(stats_str, " ", trim: true) do
          [rx_bytes, _, _, _, _, _, _, _, tx_bytes | _] ->
            case {Integer.parse(rx_bytes), Integer.parse(tx_bytes)} do
              {{rx, ""}, {tx, ""}} ->
                Map.put(acc, iface, %{rx: rx, tx: tx})

              _ ->
                acc
            end

          _ ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp parse_net_dev(_), do: %{}

  defp extract_metrics(interfaces) when is_map(interfaces) do
    # Look for tailscale0 interface first
    tailscale_iface =
      Enum.find(Map.keys(interfaces), fn name ->
        String.starts_with?(name, "tailscale")
      end)

    if tailscale_iface do
      stats = Map.get(interfaces, tailscale_iface)
      # For tailscale inbound interface:
      # Bytes Received (Download) = Tx (sent to client)
      # Bytes Sent (Upload) = Rx (received from client)
      %{bytes_received: stats.tx, bytes_sent: stats.rx}
    else
      # Fallback to wg0
      case Map.get(interfaces, "wg0") do
        %{rx: rx, tx: tx} ->
          # For wg0 outbound interface:
          # Bytes Received = Rx (received from internet)
          # Bytes Sent = Tx (sent to internet)
          %{bytes_received: rx, bytes_sent: tx}

        nil ->
          %{bytes_received: 0, bytes_sent: 0}
      end
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

  defp get_wg_listen_port(wg_name) do
    cache_key = {:wg_listen_port, wg_name}

    case Process.get(cache_key) do
      nil ->
        port = fetch_wg_listen_port(wg_name)
        if port, do: Process.put(cache_key, port)
        port

      port ->
        port
    end
  end

  defp fetch_wg_listen_port(wg_name) do
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

  defp run_cmd(cmd, args) do
    flat_args = List.flatten(args)
    Logger.info("Running: #{cmd} #{Enum.join(flat_args, " ")}")

    case System.cmd(cmd, flat_args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, code} ->
        Logger.error(
          "Command failed: #{cmd} #{Enum.join(flat_args, " ")} (exit code #{code}): #{output}"
        )

        {:error, {code, String.trim(output)}}
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
end
