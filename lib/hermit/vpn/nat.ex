defmodule Hermit.Vpn.Nat do
  @moduledoc """
  Unified helper module for setting up and tearing down nftables NAT & forwarding rules
  on the container default network namespace for both DNS Endpoints and VPN Tunnels.
  """
  require Logger

  @doc """
  Sets up a clean, single-table nftables NAT structure for a given endpoint or tunnel pair.
  Includes inbound DNAT, port-preserving outbound SNAT with container IP, and subnet masquerading.
  """
  def setup_nat(table_name, subnet, ns_ip, ts_port \\ nil) when is_binary(table_name) do
    container_ip = Hermit.Vpn.Inbound.Tailscale.get_container_ip()

    try do
      # 1. Clean up any existing table to avoid duplicate rules
      System.cmd("nft", ["delete", "table", "ip", table_name])

      # 2. Create fresh table and core chains
      System.cmd("nft", ["add", "table", "ip", table_name])
      System.cmd("nft", ["add", "chain", "ip", table_name, "prerouting", "{ type nat hook prerouting priority dstnat ; }"])
      System.cmd("nft", ["add", "chain", "ip", table_name, "postrouting", "{ type nat hook postrouting priority srcnat ; }"])
      System.cmd("nft", ["add", "chain", "ip", table_name, "forward", "{ type filter hook forward priority filter ; }"])

      # 3. Allow subnet forwarding
      if subnet && subnet != "" do
        System.cmd("nft", ["add", "rule", "ip", table_name, "forward", "ip", "saddr", subnet, "accept"])
        System.cmd("nft", ["add", "rule", "ip", table_name, "forward", "ip", "daddr", subnet, "accept"])
      end

      # 4. Inbound DNAT and Outbound SNAT for Tailscale (if ts_port configured)
      if is_integer(ts_port) and ts_port > 0 and ns_ip && ns_ip != "" do
        # Inbound DNAT: Forward UDP packets on ts_port to inner network namespace
        System.cmd("nft", [
          "add", "rule", "ip", table_name, "prerouting",
          "udp", "dport", to_string(ts_port),
          "dnat", "to", "#{ns_ip}:#{ts_port}"
        ])

        # Outbound SNAT: Rewrite saddr to container_ip and preserve sport ts_port (runs BEFORE masquerade)
        snat_args =
          if container_ip do
            ["snat", "to", "#{container_ip}:#{ts_port}"]
          else
            ["masquerade", "to", ":#{ts_port}"]
          end

        System.cmd("nft", [
          "add", "rule", "ip", table_name, "postrouting",
          "ip", "saddr", ns_ip,
          "udp", "sport", to_string(ts_port)
        ] ++ snat_args)
      end

      # 5. General subnet masquerade (placed AFTER specific SNAT rule)
      if subnet && subnet != "" do
        System.cmd("nft", ["add", "rule", "ip", table_name, "postrouting", "ip", "saddr", subnet, "masquerade"])
      end

      :ok
    rescue
      e ->
        Logger.warning("Failed to setup nftables NAT rules for #{table_name}: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Deletes the nftables table associated with a given endpoint or tunnel pair.
  """
  def cleanup_nat(table_name) when is_binary(table_name) do
    try do
      System.cmd("nft", ["delete", "table", "ip", table_name])
      :ok
    rescue
      _ -> :ok
    end
  end

  def cleanup_nat(_), do: :ok
end
