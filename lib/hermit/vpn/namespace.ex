defmodule Hermit.Vpn.Namespace do
  @moduledoc """
  Dedicated module for managing Linux Network Namespace lifecycles, veth pair interfaces (`eth0`),
  and integrating container host NAT forwarding across Hermit VPN Tunnels and DNS Endpoints.
  """
  require Logger

  @doc """
  Ensures an isolated network namespace exists for a pair_id with a standard `eth0` veth interface
  connected to the container host, and sets up host NAT forwarding.
  """
  def create_pair_namespace(pair_id) when is_binary(pair_id) do
    ns = "hermit_wg_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Created namespace #{ns}")
      {:ok, %{ns: ns, ns_ip: "10.200.1.2", subnet: "10.200.1.0/30", host_if: "loc_mock"}}
    else
      # Calculate dynamic subnet based on pair_id hash
      hash = :erlang.phash2(pair_id, 250) + 1
      ns_ip = "10.200.#{hash}.2"
      local_ip = "10.200.#{hash}.2/30"
      host_ip = "10.200.#{hash}.1/30"
      subnet = "10.200.#{hash}.0/30"

      unique_suffix =
        :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

      veth_host_if = "loc_" <> unique_suffix
      veth_ns_temp_if = "vns_" <> String.slice(unique_suffix, 0, 8)

      try do
        # Create namespace if it does not exist
        unless netns_exists?(ns) do
          run_cmd("ip", ["netns", "add", ns])
        end

        # Create veth pair if host interface does not exist
        unless link_exists?(veth_host_if) do
          run_cmd("ip", [
            "link",
            "add",
            veth_host_if,
            "type",
            "veth",
            "peer",
            "name",
            veth_ns_temp_if
          ])

          run_cmd("ip", ["link", "set", veth_ns_temp_if, "netns", ns])

          run_cmd("ip", [
            "netns",
            "exec",
            ns,
            "ip",
            "link",
            "set",
            veth_ns_temp_if,
            "name",
            "eth0"
          ])

          run_cmd("ip", ["netns", "exec", ns, "ip", "addr", "add", local_ip, "dev", "eth0"])
          run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "up"])

          run_cmd("ip", ["addr", "add", host_ip, "dev", veth_host_if])
          run_cmd("ip", ["link", "set", veth_host_if, "up"])
          run_cmd("sysctl", ["-w", "net.ipv4.conf.#{veth_host_if}.rp_filter=0"])
        end

        # Enable loopback in netns
        run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"])

        # Setup host NAT table
        Hermit.Vpn.Nat.setup_nat("hermit_local_#{pair_id}", subnet, ns_ip)

        {:ok, %{ns: ns, ns_ip: ns_ip, subnet: subnet, host_if: veth_host_if}}
      rescue
        e ->
          Logger.warning("Failed to create network namespace #{ns}: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  @doc """
  Tears down the network namespace, veth interfaces, and host NAT rules for a pair_id.
  """
  def destroy_pair_namespace(pair_id) when is_binary(pair_id) do
    ns = "hermit_wg_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Destroyed namespace #{ns}")
      :ok
    else
      unique_suffix =
        :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 11)

      veth_host_if = "loc_" <> unique_suffix

      try do
        # Delete host veth interface
        if link_exists?(veth_host_if) do
          run_cmd("ip", ["link", "delete", veth_host_if])
        end

        # Delete netns
        if netns_exists?(ns) do
          run_cmd("ip", ["netns", "del", ns])
        end

        # Remove netns DNS configuration directory
        File.rm_rf("/etc/netns/#{ns}")

        # Clean up nftables host NAT rules
        Hermit.Vpn.Nat.cleanup_nat("hermit_local_#{pair_id}")
        :ok
      rescue
        e ->
          Logger.warning("Error destroying namespace #{ns}: #{inspect(e)}")
          :ok
      end
    end
  end

  def destroy_pair_namespace(_), do: :ok

  @doc """
  Ensures an isolated network namespace exists for a DNS endpoint_id with a standard `eth0` veth interface
  connected to the container host, and sets up host NAT forwarding.
  """
  def create_endpoint_namespace(endpoint_id, ts_port \\ nil) do
    ns = "hermit_dns_endpoint_#{endpoint_id}"

    endpoint_int =
      if is_binary(endpoint_id), do: String.to_integer(endpoint_id), else: endpoint_id

    octet = div(endpoint_int, 250) |> rem(250)

    if mock?() do
      Logger.info("Mock: Created endpoint namespace #{ns}")

      {:ok,
       %{
         ns: ns,
         ns_ip: "10.251.#{octet}.2",
         subnet: "10.251.#{octet}.0/30",
         host_if: "dns_h_#{endpoint_id}"
       }}
    else
      ns_ip = "10.251.#{octet}.2"
      local_ip = "10.251.#{octet}.2/30"
      host_ip = "10.251.#{octet}.1/30"
      subnet = "10.251.#{octet}.0/30"

      veth_host_if = "dns_h_#{endpoint_id}"
      veth_ns_temp_if = "dns_n_#{endpoint_id}"

      try do
        unless netns_exists?(ns) do
          run_cmd("ip", ["netns", "add", ns])
        end

        unless link_exists?(veth_host_if) do
          run_cmd("ip", [
            "link",
            "add",
            veth_host_if,
            "type",
            "veth",
            "peer",
            "name",
            veth_ns_temp_if
          ])

          run_cmd("ip", ["link", "set", veth_ns_temp_if, "netns", ns])

          run_cmd("ip", [
            "netns",
            "exec",
            ns,
            "ip",
            "link",
            "set",
            veth_ns_temp_if,
            "name",
            "eth0"
          ])

          run_cmd("ip", ["netns", "exec", ns, "ip", "addr", "add", local_ip, "dev", "eth0"])
          run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "eth0", "up"])

          run_cmd("ip", ["addr", "add", host_ip, "dev", veth_host_if])
          run_cmd("ip", ["link", "set", veth_host_if, "up"])
          run_cmd("sysctl", ["-w", "net.ipv4.conf.#{veth_host_if}.rp_filter=0"])
        end

        run_cmd("ip", ["netns", "exec", ns, "ip", "link", "set", "lo", "up"])

        table_name = "hermit_dns_endpoint_#{endpoint_id}"
        Hermit.Vpn.Nat.setup_nat(table_name, subnet, ns_ip, ts_port)

        {:ok, %{ns: ns, ns_ip: ns_ip, subnet: subnet, host_if: veth_host_if}}
      rescue
        e ->
          Logger.warning("Failed to create endpoint namespace #{ns}: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  @doc """
  Tears down the network namespace, veth interfaces, and host NAT rules for a DNS endpoint_id.
  """
  def destroy_endpoint_namespace(endpoint_id) do
    ns = "hermit_dns_endpoint_#{endpoint_id}"

    if mock?() do
      Logger.info("Mock: Destroyed endpoint namespace #{ns}")
      :ok
    else
      veth_host_if = "dns_h_#{endpoint_id}"

      try do
        if link_exists?(veth_host_if) do
          run_cmd("ip", ["link", "delete", veth_host_if])
        end

        if netns_exists?(ns) do
          run_cmd("ip", ["netns", "del", ns])
        end

        File.rm_rf("/etc/netns/#{ns}")
        Hermit.Vpn.Nat.cleanup_nat("hermit_dns_endpoint_#{endpoint_id}")
        :ok
      rescue
        e ->
          Logger.warning("Error destroying endpoint namespace #{ns}: #{inspect(e)}")
          :ok
      end
    end
  end

  # Private Helpers

  defp netns_exists?(ns) do
    try do
      case System.cmd("ip", ["netns", "list"]) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.any?(fn line -> String.starts_with?(String.trim(line), ns) end)

        _ ->
          false
      end
    rescue
      _ -> false
    end
  end

  defp link_exists?(if_name) do
    try do
      case System.cmd("ip", ["link", "show", if_name], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  defp run_cmd(cmd, args) do
    try do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    rescue
      e -> {:error, e}
    end
  end

  defp mock? do
    Application.get_env(:hermit, :environment, :prod) == :test and
      not Application.get_env(:hermit, :test_with_real_netns, false)
  end
end
