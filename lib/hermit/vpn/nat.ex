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
      # 1. Build batched nftables ruleset
      base_commands = [
        "add table ip #{table_name}",
        "flush table ip #{table_name}",
        "add chain ip #{table_name} prerouting { type nat hook prerouting priority dstnat ; }",
        "add chain ip #{table_name} postrouting { type nat hook postrouting priority srcnat ; }",
        "add chain ip #{table_name} forward { type filter hook forward priority filter ; }"
      ]

      subnet_forward_commands =
        if subnet && subnet != "" do
          [
            "add rule ip #{table_name} forward ip saddr #{subnet} accept",
            "add rule ip #{table_name} forward ip daddr #{subnet} accept"
          ]
        else
          []
        end

      tailscale_commands =
        if (is_integer(ts_port) and ts_port > 0 and ns_ip) && ns_ip != "" do
          snat_action =
            if container_ip do
              "snat to #{container_ip}:#{ts_port}"
            else
              "masquerade to :#{ts_port}"
            end

          [
            "add rule ip #{table_name} prerouting udp dport #{ts_port} dnat to #{ns_ip}:#{ts_port}",
            "add rule ip #{table_name} postrouting ip saddr #{ns_ip} udp sport #{ts_port} #{snat_action}"
          ]
        else
          []
        end

      masquerade_commands =
        if subnet && subnet != "" do
          ["add rule ip #{table_name} postrouting ip saddr #{subnet} masquerade"]
        else
          []
        end

      all_commands =
        base_commands ++ subnet_forward_commands ++ tailscale_commands ++ masquerade_commands

      script = Enum.join(all_commands, "\n") <> "\n"

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "hermit_nat_#{table_name}_#{System.unique_integer([:positive])}.conf"
        )

      try do
        File.write!(tmp_path, script)

        case System.cmd("nft", ["-f", tmp_path], stderr_to_stdout: true) do
          {_, 0} ->
            :ok

          {error_output, _code} ->
            Logger.warning("Failed to batch apply nftables NAT rules for #{table_name}: #{error_output}")
        end
      after
        File.rm(tmp_path)
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
      System.cmd("nft", ["delete", "table", "ip", table_name], stderr_to_stdout: true)
      :ok
    rescue
      _ -> :ok
    end
  end

  def cleanup_nat(_), do: :ok
end
