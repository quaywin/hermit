defmodule Hermit.Vpn.Outbound.WarpBridge do
  @moduledoc """
  Manages the shared isolated IPv6 transport network namespace (`hermit_warp_v6_bridge`)
  used on IPv4-only hosts so Cloudflare WARP NAT64 tunnels can create their WireGuard
  UDP sockets inside a working IPv6-capable namespace without touching host routing.
  """
  use GenServer
  require Logger

  @bridge_ns "hermit_warp_v6_bridge"
  @bridge_if "wg_warp_br"
  @warp_ipv4_endpoint "162.159.192.1:2408"

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the shared bridge network namespace name.
  """
  def bridge_ns, do: @bridge_ns

  @doc """
  Ensures the IPv6 bridge namespace is up and registers `pair_id` as an active consumer.
  """
  def ensure_bridge(pair_id) when is_binary(pair_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :warp_bridge_not_running}
      pid -> GenServer.call(pid, {:ensure_bridge, pair_id}, 30_000)
    end
  end

  @doc """
  Unregisters `pair_id` from the bridge and tears down the namespace when no consumers remain.
  """
  def release_bridge(pair_id) when is_binary(pair_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, {:release_bridge, pair_id}, 15_000)
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Returns the MapSet of active pair IDs currently using the bridge.
  """
  def active_pairs do
    case GenServer.whereis(__MODULE__) do
      nil -> MapSet.new()
      pid -> GenServer.call(pid, :active_pairs)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{active_pairs: MapSet.new(), bridge_ready?: false}}
  end

  @impl true
  def handle_call(:active_pairs, _from, state) do
    {:reply, state.active_pairs, state}
  end

  @impl true
  def handle_call({:ensure_bridge, pair_id}, _from, state) do
    cond do
      mock?() ->
        new_pairs = MapSet.put(state.active_pairs, pair_id)
        {:reply, {:ok, @bridge_ns}, %{state | active_pairs: new_pairs, bridge_ready?: true}}

      bridge_healthy?() ->
        new_pairs = MapSet.put(state.active_pairs, pair_id)
        {:reply, {:ok, @bridge_ns}, %{state | active_pairs: new_pairs, bridge_ready?: true}}

      true ->
        case start_bridge() do
          :ok ->
            new_pairs = MapSet.put(state.active_pairs, pair_id)
            {:reply, {:ok, @bridge_ns}, %{state | active_pairs: new_pairs, bridge_ready?: true}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | bridge_ready?: false}}
        end
    end
  end

  @impl true
  def handle_call({:release_bridge, pair_id}, _from, state) do
    new_pairs = MapSet.delete(state.active_pairs, pair_id)

    new_ready? =
      if MapSet.size(new_pairs) == 0 and state.bridge_ready? do
        if not mock?(), do: teardown_bridge()
        false
      else
        state.bridge_ready?
      end

    {:reply, :ok, %{state | active_pairs: new_pairs, bridge_ready?: new_ready?}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.bridge_ready? and not mock?() do
      teardown_bridge()
    end

    :ok
  end

  # --- Internal Bridge Lifecycle ---

  defp start_bridge do
    teardown_bridge()

    bridge_storage_dir = Path.join(storage_base_path(), "_warp_v6_bridge")
    File.mkdir_p!(bridge_storage_dir)

    with {:ok, account} <- Hermit.Vpn.Outbound.Warp.ensure_account(bridge_storage_dir),
         stripped_path = write_stripped_config(bridge_storage_dir, account),
         {:ok, _} <- run_cmd("ip", ["netns", "add", @bridge_ns]),
         {:ok, _} <- run_cmd("ip", ["link", "add", @bridge_if, "type", "wireguard"]),
         {:ok, _} <- run_cmd("ip", ["link", "set", @bridge_if, "netns", @bridge_ns]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
             "ip",
             "link",
             "set",
             "dev",
             @bridge_if,
             "name",
             "wg0"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
             "ip",
             "link",
             "set",
             "mtu",
             "1380",
             "dev",
             "wg0"
           ]),
         {:ok, _} <-
           run_cmd("ip", ["netns", "exec", @bridge_ns, "ip", "link", "set", "lo", "up"]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
             "sysctl",
             "-w",
             "net.ipv6.conf.all.disable_ipv6=0",
             "net.ipv6.conf.default.disable_ipv6=0",
             "net.ipv4.udp_rmem_min=8192",
             "net.ipv4.udp_wmem_min=8192"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
             "ip",
             "addr",
             "add",
             "#{account["v4"]}/32",
             "dev",
             "wg0"
           ]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
             "ip",
             "-6",
             "addr",
             "add",
             "#{account["v6"]}/128",
             "dev",
             "wg0"
           ]),
         {:ok, _} <-
           run_cmd("timeout", [
             "5",
             "ip",
             "netns",
             "exec",
             @bridge_ns,
             "wg",
             "setconf",
             "wg0",
             stripped_path
           ]),
         {:ok, _} <-
           run_cmd("ip", ["netns", "exec", @bridge_ns, "ip", "link", "set", "wg0", "up"]),
         {:ok, _} <-
           run_cmd("ip", [
             "netns",
             "exec",
             @bridge_ns,
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
             @bridge_ns,
             "ip",
             "-6",
             "route",
             "add",
             "default",
             "dev",
             "wg0"
           ]),
         :ok <- setup_bridge_dns(),
         :ok <- verify_bridge_ipv6(3) do
      Logger.info("WARP IPv6 bridge namespace #{@bridge_ns} is ready.")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to start WARP IPv6 bridge: #{inspect(reason)}")
        teardown_bridge()
        {:error, {:warp_bridge_failed, reason}}
    end
  end

  defp write_stripped_config(storage_dir, account) do
    stripped_path = Path.join(storage_dir, "wg_stripped.conf")

    content = """
    [Interface]
    PrivateKey = #{account["private_key"]}

    [Peer]
    PublicKey = #{account["peer_public_key"]}
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = #{@warp_ipv4_endpoint}
    PersistentKeepalive = 25
    """

    File.write!(stripped_path, content)
    File.chmod!(stripped_path, 0o600)
    stripped_path
  end

  defp setup_bridge_dns do
    dns_dir = "/etc/netns/#{@bridge_ns}"
    File.mkdir_p!(dns_dir)

    File.write!(
      Path.join(dns_dir, "resolv.conf"),
      "nameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\n"
    )

    :ok
  end

  defp verify_bridge_ipv6(0), do: {:error, :ipv6_connectivity_check_failed}

  defp verify_bridge_ipv6(attempts_left) do
    case System.cmd(
           "ip",
           [
             "netns",
             "exec",
             @bridge_ns,
             "ping",
             "-6",
             "-c",
             "1",
             "-W",
             "2",
             "2606:4700:4700::1111"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        Process.sleep(500)
        verify_bridge_ipv6(attempts_left - 1)
    end
  end

  defp bridge_healthy? do
    netns_exists?(@bridge_ns) and
      case System.cmd("ip", ["netns", "exec", @bridge_ns, "ip", "link", "show", "wg0"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> true
        _ -> false
      end
  end

  defp teardown_bridge do
    Logger.info("Tearing down WARP IPv6 bridge namespace #{@bridge_ns}")

    case System.cmd("ip", ["link", "show", @bridge_if], stderr_to_stdout: true) do
      {_, 0} -> System.cmd("ip", ["link", "delete", @bridge_if], stderr_to_stdout: true)
      _ -> :ok
    end

    if netns_exists?(@bridge_ns) do
      _ = System.cmd("ip", ["netns", "del", @bridge_ns], stderr_to_stdout: true)
    end

    File.rm_rf("/etc/netns/#{@bridge_ns}")
    :ok
  rescue
    _ -> :ok
  end

  defp netns_exists?(ns_name) do
    case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line -> String.starts_with?(String.trim(line), ns_name) end)

      _ ->
        false
    end
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {code, String.trim(output)}}
    end
  end

  defp storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
