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
  @warp_endpoints [
    "162.159.192.1:2408",
    "162.159.192.5:500",
    "162.159.193.10:4500",
    "162.159.192.1:1701"
  ]
  @health_check_interval_ms 60_000
  @handshake_max_age_sec 180

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the shared bridge network namespace name.
  """
  def bridge_ns, do: @bridge_ns

  @doc """
  Returns the ordered list of Cloudflare WARP IPv4 endpoints used for bridge failover.
  """
  def endpoints, do: @warp_endpoints

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
  Rebuilds the shared IPv6 bridge on a rotated endpoint if it is unhealthy,
  and triggers a WireGuard restart for any other active consumer pairs.
  """
  def rebuild_if_unhealthy(triggering_pair_id \\ nil) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :warp_bridge_not_running}
      pid -> GenServer.call(pid, {:rebuild_if_unhealthy, triggering_pair_id}, 30_000)
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

  @doc """
  Parses `wg show wg0 latest-handshakes` output and returns `{:ok, unix_ts}` or `:none`.
  """
  def parse_latest_handshake(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:none, fn line ->
      case String.split(String.trim(line)) do
        [_peer, ts_str | _] ->
          case Integer.parse(ts_str) do
            {ts, ""} when ts > 0 -> {:ok, ts}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  def parse_latest_handshake(_), do: :none

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{active_pairs: MapSet.new(), bridge_ready?: false, endpoint_index: 0, health_timer: nil}}
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

      state.bridge_ready? and bridge_healthy?() ->
        new_pairs = MapSet.put(state.active_pairs, pair_id)
        new_state = %{state | active_pairs: new_pairs} |> ensure_health_check_scheduled()
        {:reply, {:ok, @bridge_ns}, new_state}

      true ->
        case start_bridge(state.endpoint_index) do
          {:ok, used_index} ->
            new_pairs = MapSet.put(state.active_pairs, pair_id)

            new_state =
              %{state | active_pairs: new_pairs, bridge_ready?: true, endpoint_index: used_index}
              |> schedule_health_check()

            {:reply, {:ok, @bridge_ns}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | bridge_ready?: false}}
        end
    end
  end

  @impl true
  def handle_call({:rebuild_if_unhealthy, triggering_pair_id}, _from, state) do
    cond do
      mock?() ->
        {:reply, :ok, state}

      bridge_healthy?() ->
        {:reply, :ok, state}

      true ->
        Logger.warning(
          "WARP IPv6 bridge unhealthy; rebuilding with rotated Cloudflare endpoint..."
        )

        case start_bridge(state.endpoint_index + 1) do
          {:ok, used_index} ->
            state.active_pairs
            |> Enum.reject(&(&1 == triggering_pair_id))
            |> restart_consumer_pairs_async()

            new_state =
              %{state | bridge_ready?: true, endpoint_index: used_index}
              |> schedule_health_check()

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | bridge_ready?: false}}
        end
    end
  end

  @impl true
  def handle_call({:release_bridge, pair_id}, _from, state) do
    new_pairs = MapSet.delete(state.active_pairs, pair_id)

    {new_ready?, new_timer} =
      if MapSet.size(new_pairs) == 0 do
        cancel_health_check(state.health_timer)
        if state.bridge_ready? and not mock?(), do: teardown_bridge()
        {false, nil}
      else
        {state.bridge_ready?, state.health_timer}
      end

    {:reply, :ok,
     %{state | active_pairs: new_pairs, bridge_ready?: new_ready?, health_timer: new_timer}}
  end

  @impl true
  def handle_info(:health_check, state) do
    cond do
      MapSet.size(state.active_pairs) == 0 or mock?() ->
        {:noreply, %{state | health_timer: nil}}

      bridge_healthy?() ->
        {:noreply, schedule_health_check(state)}

      true ->
        Logger.warning("Periodic check detected unhealthy WARP IPv6 bridge; auto-healing...")

        case start_bridge(state.endpoint_index + 1) do
          {:ok, used_index} ->
            state.active_pairs
            |> MapSet.to_list()
            |> restart_consumer_pairs_async()

            new_state =
              %{state | bridge_ready?: true, endpoint_index: used_index}
              |> schedule_health_check()

            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("Failed to auto-heal WARP IPv6 bridge: #{inspect(reason)}")
            {:noreply, schedule_health_check(%{state | bridge_ready?: false})}
        end
    end
  end

  @impl true
  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_health_check(state.health_timer)

    if state.bridge_ready? and not mock?() do
      teardown_bridge()
    end

    :ok
  end

  # --- Internal Bridge Lifecycle ---

  defp start_bridge(start_index) do
    bridge_storage_dir = Path.join(storage_base_path(), "_warp_v6_bridge")
    File.mkdir_p!(bridge_storage_dir)

    case Hermit.Vpn.Outbound.Warp.ensure_account(bridge_storage_dir) do
      {:ok, account} ->
        count = length(@warp_endpoints)
        base = rem(max(start_index, 0), count)

        0..(count - 1)
        |> Enum.reduce_while({:error, :no_endpoints}, fn offset, _acc ->
          idx = rem(base + offset, count)
          endpoint = Enum.at(@warp_endpoints, idx)

          case start_bridge_with_endpoint(bridge_storage_dir, account, endpoint) do
            :ok ->
              {:halt, {:ok, idx}}

            {:error, reason} ->
              Logger.warning(
                "WARP IPv6 bridge failed on endpoint #{endpoint}: #{inspect(reason)}"
              )

              teardown_bridge()
              {:cont, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, {:warp_bridge_account_failed, reason}}
    end
  end

  defp start_bridge_with_endpoint(bridge_storage_dir, account, endpoint) do
    teardown_bridge()

    with stripped_path = write_stripped_config(bridge_storage_dir, account, endpoint),
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
             "1420",
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
         :ok <- verify_bridge_ipv6(2) do
      enable_udp_gro()
      Logger.info("WARP IPv6 bridge namespace #{@bridge_ns} is ready via #{endpoint}.")
      :ok
    else
      {:error, reason} ->
        teardown_bridge()
        {:error, {:warp_bridge_failed, reason}}
    end
  end

  defp enable_udp_gro do
    case run_cmd("ip", [
           "netns",
           "exec",
           @bridge_ns,
           "ethtool",
           "-K",
           "wg0",
           "rx-udp-gro-forwarding",
           "on",
           "rx-gro-list",
           "off"
         ]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not enable UDP GRO forwarding on wg0 in #{@bridge_ns}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp write_stripped_config(storage_dir, account, endpoint) do
    stripped_path = Path.join(storage_dir, "wg_stripped.conf")

    content = """
    [Interface]
    PrivateKey = #{account["private_key"]}

    [Peer]
    PublicKey = #{account["peer_public_key"]}
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = #{endpoint}
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
      match?(
        {_, 0},
        System.cmd("ip", ["netns", "exec", @bridge_ns, "ip", "link", "show", "wg0"],
          stderr_to_stdout: true
        )
      ) and
      (recent_handshake?() or bridge_ping_ok?())
  end

  defp recent_handshake? do
    case System.cmd(
           "ip",
           ["netns", "exec", @bridge_ns, "wg", "show", "wg0", "latest-handshakes"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case parse_latest_handshake(output) do
          {:ok, ts} -> System.system_time(:second) - ts <= @handshake_max_age_sec
          :none -> false
        end

      _ ->
        false
    end
  end

  defp bridge_ping_ok? do
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
      {_, 0} -> true
      _ -> false
    end
  end

  defp restart_consumer_pairs_async(pair_ids) do
    Enum.each(pair_ids, fn pair_id ->
      Task.start(fn ->
        Logger.info("Restarting WARP NAT64 consumer tunnel #{pair_id} after bridge rebuild")
        Hermit.Vpn.PairWorker.restart_wg(pair_id)
      end)
    end)
  end

  defp ensure_health_check_scheduled(%{health_timer: nil} = state) do
    schedule_health_check(state)
  end

  defp ensure_health_check_scheduled(state), do: state

  defp schedule_health_check(state) do
    cancel_health_check(state.health_timer)
    timer = Process.send_after(self(), :health_check, @health_check_interval_ms)
    %{state | health_timer: timer}
  end

  defp cancel_health_check(nil), do: :ok

  defp cancel_health_check(timer) do
    Process.cancel_timer(timer)
    :ok
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
