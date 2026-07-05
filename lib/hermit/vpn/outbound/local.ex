defmodule Hermit.Vpn.Outbound.Local do
  @behaviour Hermit.Vpn.Outbound
  require Logger

  @impl true
  def bootstrap(pair_id, storage_dir, config) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      mock?() ->
        Logger.info(
          "Mock: Creating Local outbound tunnel #{wg_name} inside storage #{storage_dir}"
        )

        {:ok, "eth0"}

      true ->
        Logger.info("Creating local netns for local outbound: #{wg_name}")

        if netns_exists?(wg_name) do
          Logger.warning(
            "Stale network namespace found: #{wg_name}. Performing cleanup before recreation."
          )

          cleanup(pair_id, storage_dir)
        end

        # Calculate dynamic subnet based on pair_id hash if not configured
        hash = :erlang.phash2(pair_id, 250) + 1

        local_ip =
          Map.get(config, "local_ip") || Map.get(config, :local_ip) || "10.200.#{hash}.2/30"

        host_ip = Map.get(config, "host_ip") || Map.get(config, :host_ip) || "10.200.#{hash}.1/30"
        gateway = String.split(host_ip, "/") |> hd()

        subnet =
          case String.split(local_ip, ".") do
            [a, b, c, d_cidr] ->
              [_, cidr] = String.split(d_cidr, "/")
              "#{a}.#{b}.#{c}.0/#{cidr}"

            _ ->
              "10.200.#{hash}.0/30"
          end

        # Create unique interface suffix to prevent collisions on host
        unique_suffix =
          :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

        host_if_name = "loc_" <> unique_suffix
        ns_temp_if = "vns_" <> String.slice(unique_suffix, 0, 8)

        netns_dns_dir = "/etc/netns/#{wg_name}"

        # Execute network setup steps sequentially
        result =
          with {:ok, _} <- run_cmd("ip", ["netns", "add", wg_name]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "link",
                   "add",
                   host_if_name,
                   "type",
                   "veth",
                   "peer",
                   "name",
                   ns_temp_if
                 ]),
               {:ok, _} <- run_cmd("ip", ["link", "set", ns_temp_if, "netns", wg_name]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "link",
                   "set",
                   ns_temp_if,
                   "name",
                   "eth0"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "addr",
                   "add",
                   local_ip,
                   "dev",
                   "eth0"
                 ]),
               {:ok, _} <-
                 run_cmd("ip", [
                   "netns",
                   "exec",
                   wg_name,
                   "ip",
                   "link",
                   "set",
                   "eth0",
                   "up"
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
                   "ip",
                   "route",
                   "add",
                   "default",
                   "via",
                   gateway,
                   "dev",
                   "eth0"
                 ]),
             {:ok, _} <- run_cmd("ip", ["addr", "add", host_ip, "dev", host_if_name]),
             {:ok, _} <- run_cmd("ip", ["link", "set", host_if_name, "up"]),
             {:ok, _} <- run_cmd("sysctl", ["-w", "net.ipv4.conf.#{host_if_name}.rp_filter=0"]),
             # Add route for Tailscale range to satisfy rp_filter=2 (ignore if already exists)
             _ = run_cmd("ip", ["route", "add", "100.64.0.0/10", "dev", host_if_name]),
             {:ok, _} <-
               run_cmd("iptables", [
                 "-t",
                 "nat",
                  "-I",
                  "POSTROUTING",
                  "-s",
                  subnet,
                  "-j",
                  "MASQUERADE"
                ]),
              {:ok, _} <- run_cmd("iptables", ["-I", "FORWARD", "-s", subnet, "-j", "ACCEPT"]),
              {:ok, _} <-
                run_cmd("iptables", [
                  "-I",
                  "FORWARD",
                  "-d",
                  subnet,
                  "-m",
                  "state",
                  "--state",
                  "ESTABLISHED,RELATED",
                  "-j",
                  "ACCEPT"
                ]) do
            # Setup network namespace DNS
            dns_servers =
              (Map.get(config, "dns_servers") || Map.get(config, :dns_servers) || [])
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))

            if dns_servers != [] do
              File.mkdir_p!(netns_dns_dir)
              dns_lines = dns_servers |> Enum.map(&"nameserver #{&1}") |> Enum.join("\n")
              File.write!(Path.join(netns_dns_dir, "resolv.conf"), dns_lines)
            else
              if File.exists?("/etc/resolv.conf") do
                File.mkdir_p!(netns_dns_dir)
                File.copy!("/etc/resolv.conf", Path.join(netns_dns_dir, "resolv.conf"))
              end
            end

            {:ok, "eth0"}
          else
            {:error, reason} ->
              {:error, reason}
          end

        # Rollback/cleanup on error
        case result do
          {:ok, _} ->
            {:ok, "eth0"}

          {:error, reason} ->
            System.cmd("ip", ["link", "delete", host_if_name])
            System.cmd("ip", ["netns", "del", wg_name])
            File.rm_rf(netns_dns_dir)

            System.cmd("iptables", [
              "-t",
              "nat",
              "-D",
              "POSTROUTING",
              "-s",
              subnet,
              "-j",
              "MASQUERADE"
            ])

            System.cmd("iptables", ["-D", "FORWARD", "-s", subnet, "-j", "ACCEPT"])

            System.cmd("iptables", [
              "-D",
              "FORWARD",
              "-d",
              subnet,
              "-m",
              "state",
              "--state",
              "ESTABLISHED,RELATED",
              "-j",
              "ACCEPT"
            ])

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
      unique_suffix =
        :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

      host_if_name = "loc_" <> unique_suffix

      Logger.info("Stopping Local outbound netns: #{wg_name}")

      # Read config from database to clean up iptables rules if custom IPs were used
      pair = Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id)
      pair = if pair, do: Hermit.Repo.preload(pair, :outbound_profile), else: nil

      config =
        if pair && pair.outbound_profile, do: pair.outbound_profile.config || %{}, else: %{}

      hash = :erlang.phash2(pair_id, 250) + 1

      local_ip =
        Map.get(config, "local_ip") || Map.get(config, :local_ip) || "10.200.#{hash}.2/30"

      subnet =
        case String.split(local_ip, ".") do
          [a, b, c, d_cidr] ->
            [_, cidr] = String.split(d_cidr, "/")
            "#{a}.#{b}.#{c}.0/#{cidr}"

          _ ->
            "10.200.#{hash}.0/30"
        end

      # Delete host interface if any
      System.cmd("ip", ["link", "delete", host_if_name])

      # Delete the namespace
      if netns_exists?(wg_name) do
        System.cmd("ip", ["netns", "del", wg_name])
      end

      # Clean up netns DNS config
      File.rm_rf("/etc/netns/#{wg_name}")

      # Clean up iptables rules
      System.cmd("iptables", ["-t", "nat", "-D", "POSTROUTING", "-s", subnet, "-j", "MASQUERADE"])
      System.cmd("iptables", ["-D", "FORWARD", "-s", subnet, "-j", "ACCEPT"])

      System.cmd("iptables", [
        "-D",
        "FORWARD",
        "-d",
        subnet,
        "-m",
        "state",
        "--state",
        "ESTABLISHED,RELATED",
        "-j",
        "ACCEPT"
      ])

      :ok
    end
  end

  @impl true
  def get_status(pair_id, _storage_dir) do
    wg_name = "hermit_wg_#{pair_id}"

    cond do
      mock?() ->
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
      mock?() ->
        if File.exists?(storage_dir) do
          {:ok, %{bytes_received: 1024, bytes_sent: 2048}}
        else
          {:error, :not_found}
        end

      true ->
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
            {:ok, data}

          :error ->
            case System.cmd("ip", ["netns", "exec", wg_name, "cat", "/proc/net/dev"],
                   stderr_to_stdout: true
                 ) do
              {output, 0} ->
                interfaces = parse_net_dev(output)
                data = extract_metrics(interfaces)
                {:ok, data}

              _ ->
                :error
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
    tailscale_iface =
      Enum.find(Map.keys(interfaces), fn name ->
        String.starts_with?(name, "tailscale")
      end)

    if tailscale_iface do
      stats = Map.get(interfaces, tailscale_iface)
      %{bytes_received: stats.tx, bytes_sent: stats.rx}
    else
      case Map.get(interfaces, "eth0") do
        %{rx: rx, tx: tx} ->
          %{bytes_received: rx, bytes_sent: tx}

        nil ->
          %{bytes_received: 0, bytes_sent: 0}
      end
    end
  end

  defp get_storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
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
end
