defmodule Hermit.Vpn.DnsDeviceResolver do
  use GenServer
  require Logger

  @table :dns_device_cache

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def resolve_device(profile_id, client_ip) do
    case :ets.lookup(@table, {profile_id, client_ip}) do
      [{_, :not_found, _inserted_at}] ->
        nil

      [{_, name, _inserted_at}] ->
        name

      [] ->
        # New IP! Trigger a background update of the Tailscale node cache
        GenServer.cast(__MODULE__, {:trigger_update, profile_id})
        nil
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Pre-populate and set periodic update timer
    Process.send_after(self(), :periodic_update, 2000)
    {:ok, %{updating_profiles: MapSet.new()}}
  end

  @impl true
  def handle_info(:periodic_update, state) do
    active_profile_ids =
      try do
        import Ecto.Query
        Hermit.Repo.all(from(i in Hermit.Vpn.InboundProfile, select: i.id))
      rescue
        _ -> []
      end

    Enum.each(active_profile_ids, fn profile_id ->
      trigger_update(profile_id)
    end)

    # Schedule next update in 5 minutes (300,000 ms)
    Process.send_after(self(), :periodic_update, 300_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:trigger_update, profile_id}, state) do
    if MapSet.member?(state.updating_profiles, profile_id) do
      {:noreply, state}
    else
      new_updating = MapSet.put(state.updating_profiles, profile_id)

      parent = self()

      Task.start(fn ->
        try do
          perform_update(profile_id)
        rescue
          e -> Logger.warning("DnsDeviceResolver: perform_update failed: #{inspect(e)}")
        after
          GenServer.cast(parent, {:update_complete, profile_id})
        end
      end)

      {:noreply, %{state | updating_profiles: new_updating}}
    end
  end

  @impl true
  def handle_cast({:update_complete, profile_id}, state) do
    new_updating = MapSet.delete(state.updating_profiles, profile_id)
    {:noreply, %{state | updating_profiles: new_updating}}
  end

  # --- Helper functions ---

  defp trigger_update(profile_id) do
    GenServer.cast(__MODULE__, {:trigger_update, profile_id})
  end

  defp perform_update(profile_id) do
    now = System.system_time(:second)

    if mock?() do
      Process.sleep(10)

      :ets.insert(@table, [
        {{profile_id, "127.0.0.1"}, "localhost", now},
        {{profile_id, "100.64.0.5"}, "mock-client", now}
      ])
    else
      dns_socket = "/run/tailscaled.dns_#{profile_id}.socket"

      pair_sockets =
        try do
          import Ecto.Query

          Hermit.Repo.all(
            from(p in Hermit.Vpn.VpnPair, where: p.inbound_profile_id == ^profile_id)
          )
          |> Enum.map(fn pair -> "/run/tailscaled.#{pair.pair_id}.socket" end)
        rescue
          _ -> []
        end

      candidate_sockets = [dns_socket | pair_sockets]
      # Always insert local mappings
      :ets.insert(@table, [
        {{profile_id, "127.0.0.1"}, "localhost", now}
      ])

      # Try candidate sockets sequentially until one succeeds
      result =
        Enum.find_value(candidate_sockets, fn socket ->
          if File.exists?(socket) do
            case query_tailscale_status(socket) do
              {:ok, data} -> {:ok, socket, data}
              _ -> nil
            end
          else
            nil
          end
        end)

      case result do
        {:ok, _socket, data} ->
          nodes = extract_nodes(data)

          entries =
            Enum.flat_map(nodes, fn node ->
              dns_name = Map.get(node, "DNSName")
              hostname = Map.get(node, "HostName")
              ips = Map.get(node, "TailscaleIPs") || []
              device_name = get_device_name(dns_name, hostname)

              if device_name do
                Enum.map(ips, fn ip ->
                  {{profile_id, ip}, device_name, now}
                end)
              else
                []
              end
            end)

          if length(entries) > 0 do
            :ets.insert(@table, entries)
          end

        _ ->
          Logger.warning(
            "DnsDeviceResolver: Failed to query Tailscale status on any candidate sockets for profile #{profile_id}"
          )
      end
    end
  end

  defp query_tailscale_status(socket_path) do
    case System.cmd("tailscale", ["--socket=#{socket_path}", "status", "--json"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode_failed, reason}}
        end

      {output, code} ->
        {:error, {:command_failed, code, output}}
    end
  rescue
    e -> {:error, e}
  end

  defp extract_nodes(data) do
    self_node = Map.get(data, "Self")
    peers = Map.get(data, "Peer") || %{}
    peer_nodes = Map.values(peers)

    if self_node do
      [self_node | peer_nodes]
    else
      peer_nodes
    end
  end

  defp get_device_name(dns_name, hostname) do
    cond do
      dns_name && dns_name != "" ->
        dns_name
        |> String.split(".")
        |> List.first()

      hostname && hostname != "" ->
        hostname

      true ->
        nil
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
