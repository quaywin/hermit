defmodule Hermit.Vpn.PairWorker do
  use GenServer, restart: :transient
  require Logger

  @topic "vpn_pairs"

  defstruct [
    :id,
    :wg_container_name,
    :ts_container_name,
    :wg_config_path,
    :wg_config_content,
    :ts_auth_key,
    # Keep for legacy compatibility/overall status
    :status,
    # Keep for legacy compatibility
    :error_reason,
    # :stopped | :starting | :running | :error
    :wg_status,
    # :stopped | :starting | :running | :error
    :ts_status,
    :wg_error_reason,
    :ts_error_reason,
    :metrics,
    :storage_dir,
    :started_at,
    :ts_port,
    ts_retry_count: 0,
    wg_retry_count: 0,
    inbound_module: Hermit.Vpn.Inbound.Tailscale,
    outbound_module: Hermit.Vpn.Outbound.WireGuard,
    inbound_config: nil,
    outbound_config: nil
  ]

  # --- Client API ---

  def start_link(args) do
    # args expects a map with keys: :id, :wg_config, :ts_auth_key
    GenServer.start_link(__MODULE__, args, name: via_tuple(args.id))
  end

  def get_state(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, :get_state)
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_pair(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, :pause)
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_pair(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, :resume)
      {:error, reason} -> {:error, reason}
    end
  end

  def restart_pair(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, :restart)
      {:error, reason} -> {:error, reason}
    end
  end

  # Independent control APIs
  def start_wg(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, {:start_wg})
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_wg(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:stop_wg})
    end
  end

  def restart_wg(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, {:restart_wg})
      {:error, reason} -> {:error, reason}
    end
  end

  def update_wg_config(id, new_wg_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        if is_nil(new_wg_config) or String.trim(new_wg_config) == "" do
          changeset =
            pair
            |> Hermit.Vpn.VpnPair.changeset(%{wg_config: new_wg_config})
            |> Ecto.Changeset.add_error(:wg_config, "can't be blank")

          {:error, changeset}
        else
          if pair.outbound_profile_id do
            case Hermit.Repo.get(Hermit.Vpn.OutboundProfile, pair.outbound_profile_id) do
              nil ->
                {:error, :profile_not_found}

              profile ->
                new_config = Map.put(profile.config || %{}, "wg_config", new_wg_config)

                case profile
                     |> Hermit.Vpn.OutboundProfile.changeset(%{config: new_config})
                     |> Hermit.Repo.update() do
                  {:ok, _} ->
                    case GenServer.whereis(via_tuple(id)) do
                      nil -> {:ok, :updated_offline}
                      pid -> GenServer.call(pid, {:update_wg_config, new_wg_config})
                    end

                  {:error, _changeset} ->
                    pair_changeset =
                      pair
                      |> Hermit.Vpn.VpnPair.changeset(%{wg_config: new_wg_config})
                      |> Ecto.Changeset.add_error(:wg_config, "is invalid")

                    {:error, pair_changeset}
                end
            end
          else
            {:error, :no_outbound_profile}
          end
        end
    end
  end

  def start_ts(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, {:start_ts})
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_ts(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:stop_ts})
    end
  end

  def restart_ts(id) do
    case ensure_worker_running(id) do
      {:ok, pid} -> GenServer.call(pid, {:restart_ts})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists states for all VPN pairs.
  """
  def list_pairs do
    persisted_pairs =
      try do
        Hermit.Vpn.VpnPair
        |> Hermit.Repo.all()
        |> Hermit.Repo.preload([:inbound_profile, :outbound_profile])
      rescue
        _ -> []
      end

    persisted_ids = Enum.map(persisted_pairs, & &1.pair_id)

    registry_ids = Registry.select(Hermit.Vpn.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

    all_ids = Enum.uniq(persisted_ids ++ registry_ids)

    Enum.map(all_ids, fn id ->
      case GenServer.whereis(via_tuple(id)) do
        nil ->
          pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)

          {inbound_type, inbound_config} =
            if pair && pair.inbound_profile do
              {pair.inbound_profile.type, pair.inbound_profile.config || %{}}
            else
              {"tailscale", %{}}
            end

          {outbound_type, outbound_config} =
            if pair && pair.outbound_profile do
              {pair.outbound_profile.type, pair.outbound_profile.config || %{}}
            else
              {"wireguard", %{}}
            end

          inbound_mod =
            case inbound_type do
              "tailscale" -> Hermit.Vpn.Inbound.Tailscale
              "headscale" -> Hermit.Vpn.Inbound.Tailscale
              "zerotier" -> Hermit.Vpn.Inbound.ZeroTier
              "proxy" -> Hermit.Vpn.Inbound.Proxy
              _ -> Hermit.Vpn.Inbound.Tailscale
            end

          outbound_mod =
            case outbound_type do
              "wireguard" -> Hermit.Vpn.Outbound.WireGuard
              "openvpn" -> Hermit.Vpn.Outbound.OpenVPN
              _ -> Hermit.Vpn.Outbound.WireGuard
            end

          %__MODULE__{
            id: id,
            wg_container_name: "hermit_wg_#{id}",
            ts_container_name: "hermit_ts_#{id}",
            wg_config_path: Path.join([get_storage_base_path(), id, "wg0.conf"]),
            wg_config_content:
              Map.get(outbound_config, "wg_config") || Map.get(outbound_config, :wg_config) || "",
            ts_auth_key:
              Map.get(inbound_config, "ts_auth_key") || Map.get(inbound_config, :ts_auth_key) ||
                "",
            status: String.to_atom((pair && pair.status) || "stopped"),
            error_reason: pair && (pair.wg_error_reason || pair.ts_error_reason),
            wg_status: String.to_atom((pair && pair.wg_status) || "stopped"),
            ts_status: String.to_atom((pair && pair.ts_status) || "stopped"),
            wg_error_reason: pair && pair.wg_error_reason,
            ts_error_reason: pair && pair.ts_error_reason,
            metrics: %{
              bytes_received: 0,
              bytes_sent: 0,
              ts_ips: [],
              ts_backend_state: "Offline",
              ts_user: "Unknown",
              ts_magic_dns: "",
              ts_exit_node: false,
              wg_port: nil
            },
            storage_dir: Path.join(get_storage_base_path(), id),
            started_at: pair && pair.started_at,
            ts_port: nil,
            inbound_module: inbound_mod,
            outbound_module: outbound_mod,
            inbound_config: inbound_config,
            outbound_config: outbound_config
          }

        pid ->
          try do
            GenServer.call(pid, :get_state, 1000)
          catch
            _, _ ->
              pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)

              {inbound_type, inbound_config} =
                if pair && pair.inbound_profile do
                  {pair.inbound_profile.type, pair.inbound_profile.config || %{}}
                else
                  {"tailscale", %{}}
                end

              {outbound_type, outbound_config} =
                if pair && pair.outbound_profile do
                  {pair.outbound_profile.type, pair.outbound_profile.config || %{}}
                else
                  {"wireguard", %{}}
                end

              inbound_mod =
                case inbound_type do
                  "tailscale" -> Hermit.Vpn.Inbound.Tailscale
                  "headscale" -> Hermit.Vpn.Inbound.Tailscale
                  "zerotier" -> Hermit.Vpn.Inbound.ZeroTier
                  "proxy" -> Hermit.Vpn.Inbound.Proxy
                  _ -> Hermit.Vpn.Inbound.Tailscale
                end

              outbound_mod =
                case outbound_type do
                  "wireguard" -> Hermit.Vpn.Outbound.WireGuard
                  "openvpn" -> Hermit.Vpn.Outbound.OpenVPN
                  _ -> Hermit.Vpn.Outbound.WireGuard
                end

              %__MODULE__{
                id: id,
                wg_container_name: "hermit_wg_#{id}",
                ts_container_name: "hermit_ts_#{id}",
                wg_config_path: Path.join([get_storage_base_path(), id, "wg0.conf"]),
                wg_config_content:
                  Map.get(outbound_config, "wg_config") || Map.get(outbound_config, :wg_config) ||
                    "",
                ts_auth_key:
                  Map.get(inbound_config, "ts_auth_key") || Map.get(inbound_config, :ts_auth_key) ||
                    "",
                status: String.to_atom((pair && pair.status) || "stopped"),
                error_reason: pair && (pair.wg_error_reason || pair.ts_error_reason),
                wg_status: String.to_atom((pair && pair.wg_status) || "stopped"),
                ts_status: String.to_atom((pair && pair.ts_status) || "stopped"),
                wg_error_reason: pair && pair.wg_error_reason,
                ts_error_reason: pair && pair.ts_error_reason,
                metrics: %{
                  bytes_received: 0,
                  bytes_sent: 0,
                  ts_ips: [],
                  ts_backend_state: "Offline",
                  ts_user: "Unknown",
                  ts_magic_dns: "",
                  ts_exit_node: false,
                  wg_port: nil
                },
                storage_dir: Path.join(get_storage_base_path(), id),
                started_at: pair && pair.started_at,
                ts_port: nil,
                inbound_module: inbound_mod,
                outbound_module: outbound_mod,
                inbound_config: inbound_config,
                outbound_config: outbound_config
              }
          end
      end
    end)
  end

  defp via_tuple(id), do: {:via, Registry, {Hermit.Vpn.Registry, id}}

  defp ensure_worker_running(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil ->
        case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
          nil ->
            {:error, :not_found}

          pair ->
            case DynamicSupervisor.start_child(
                   Hermit.Vpn.DynamicSupervisor,
                   {__MODULE__,
                    %{
                      id: id,
                      inbound_profile_id: pair.inbound_profile_id,
                      outbound_profile_id: pair.outbound_profile_id
                    }}
                 ) do
              {:ok, pid} -> {:ok, pid}
              {:ok, pid, _} -> {:ok, pid}
              {:error, {:already_started, pid}} -> {:ok, pid}
              error -> error
            end
        end

      pid ->
        {:ok, pid}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    id = args.id
    storage_dir = Path.join(get_storage_base_path(), id)
    wg_config_path = Path.join(storage_dir, "wg0.conf")

    {wg_status, ts_status, overall_status, started_at, inbound_type, inbound_config,
     outbound_type,
     outbound_config} =
      case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
        nil ->
          {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
           args[:inbound_config] || %{"ts_auth_key" => args.ts_auth_key},
           args[:outbound_type] || "wireguard",
           args[:outbound_config] ||
             %{"wg_config" => args[:wg_config] || args[:wg_config_content]}}

        pair ->
          pair = Hermit.Repo.preload(pair, [:inbound_profile, :outbound_profile])

          {inbound_type, inbound_config} =
            if pair.inbound_profile do
              {pair.inbound_profile.type, pair.inbound_profile.config || %{}}
            else
              {pair.inbound_type || "tailscale", pair.inbound_config || %{}}
            end

          {outbound_type, outbound_config} =
            if pair.outbound_profile do
              {pair.outbound_profile.type, pair.outbound_profile.config || %{}}
            else
              {pair.outbound_type || "wireguard", pair.outbound_config || %{}}
            end

          {
            String.to_atom(pair.wg_status || "stopped"),
            String.to_atom(pair.ts_status || "stopped"),
            String.to_atom(pair.status || "stopped"),
            pair.started_at,
            inbound_type,
            inbound_config,
            outbound_type,
            outbound_config
          }
      end

    inbound_module =
      case inbound_type do
        "tailscale" -> Hermit.Vpn.Inbound.Tailscale
        "headscale" -> Hermit.Vpn.Inbound.Tailscale
        "zerotier" -> Hermit.Vpn.Inbound.ZeroTier
        "proxy" -> Hermit.Vpn.Inbound.Proxy
        _ -> Hermit.Vpn.Inbound.Tailscale
      end

    outbound_module =
      case outbound_type do
        "wireguard" -> Hermit.Vpn.Outbound.WireGuard
        "openvpn" -> Hermit.Vpn.Outbound.OpenVPN
        _ -> Hermit.Vpn.Outbound.WireGuard
      end

    wg_config_content =
      Map.get(outbound_config, "wg_config") ||
        Map.get(outbound_config, :wg_config) ||
        args[:wg_config] ||
        args[:wg_config_content]

    ts_auth_key =
      Map.get(inbound_config, "ts_auth_key") ||
        Map.get(inbound_config, :ts_auth_key) ||
        args[:ts_auth_key]

    state = %__MODULE__{
      id: id,
      wg_container_name: "hermit_wg_#{id}",
      ts_container_name: "hermit_ts_#{id}",
      wg_config_path: wg_config_path,
      wg_config_content: wg_config_content,
      ts_auth_key: ts_auth_key,
      status: overall_status,
      wg_status: wg_status,
      ts_status: ts_status,
      wg_error_reason: nil,
      ts_error_reason: nil,
      metrics: %{
        bytes_received: 0,
        bytes_sent: 0,
        ts_ips: [],
        ts_backend_state: "Offline",
        ts_user: "Unknown",
        ts_magic_dns: "",
        ts_exit_node: false,
        wg_port: nil
      },
      storage_dir: storage_dir,
      started_at: started_at,
      ts_port: nil,
      ts_retry_count: 0,
      wg_retry_count: 0,
      inbound_module: inbound_module,
      outbound_module: outbound_module,
      inbound_config: inbound_config,
      outbound_config: outbound_config
    }

    cond do
      wg_status == :starting and ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap}}

      wg_status == :starting ->
        {:ok, state, {:continue, :bootstrap_wg}}

      ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap_ts}}

      true ->
        if wg_status == :running do
          schedule_metrics_poll()
        end

        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    handle_continue(:bootstrap_wg, state)
  end

  @impl true
  def handle_continue(:bootstrap_wg, state) do
    Logger.info("Bootstrapping WireGuard for VPN Pair: #{state.id}")

    try do
      File.mkdir_p!(state.storage_dir)
      File.mkdir_p!(Path.join(state.storage_dir, "tailscale"))

      resolved_content = resolve_endpoint_in_config(state.wg_config_content)
      File.write!(state.wg_config_path, resolved_content)
      File.chmod!(state.wg_config_path, 0o600)

      case state.outbound_module.bootstrap(state.id, state.storage_dir, state.outbound_config) do
        {:ok, _} ->
          updated_state = %{state | wg_status: :running, wg_error_reason: nil, wg_retry_count: 0}
          updated_state = broadcast_update(updated_state)

          if state.ts_status == :starting do
            send(self(), {:check_wg_health, 10})
          end

          {:noreply, updated_state}

        {:error, reason} ->
          error_state = %{
            state
            | wg_status: :error,
              wg_error_reason: "WireGuard creation failed: #{inspect(reason)}"
          }

          updated_state = broadcast_update(error_state)
          maybe_schedule_wg_recovery(updated_state)
          {:noreply, updated_state}
      end
    rescue
      e ->
        Logger.error("Failed to write configurations or start WG: #{inspect(e)}")

        error_state = %{
          state
          | wg_status: :error,
            wg_error_reason: "Setup failure: #{Exception.message(e)}"
        }

        updated_state = broadcast_update(error_state)
        maybe_schedule_wg_recovery(updated_state)
        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_continue(:bootstrap_ts, state) do
    Logger.info("Bootstrapping Tailscale for VPN Pair: #{state.id}")
    send(self(), {:check_wg_health, 10})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  # Legacy callbacks (map to split state logic)
  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Pausing VPN pair (both components): #{state.id}")

    # Stop Inbound (Tailscale)
    if state.ts_port do
      Process.unlink(state.ts_port)
      Port.close(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    # Stop Outbound (WireGuard)
    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{
      state
      | wg_status: :stopped,
        ts_status: :stopped,
        wg_error_reason: nil,
        ts_error_reason: nil,
        ts_port: nil,
        started_at: nil,
        metrics: %{bytes_received: 0, bytes_sent: 0}
    }

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Resuming VPN pair (both components): #{state.id}")

    updated_state = %{
      state
      | wg_status: :starting,
        ts_status: :starting,
        wg_error_reason: nil,
        ts_error_reason: nil,
        wg_retry_count: 0,
        ts_retry_count: 0
    }

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_call(:restart, _from, state) do
    Logger.info("Restarting VPN pair (both components): #{state.id}")

    # Stop Inbound (Tailscale)
    if state.ts_port do
      Process.unlink(state.ts_port)
      Port.close(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    # Stop Outbound (WireGuard)
    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{
      state
      | wg_status: :starting,
        ts_status: :starting,
        wg_error_reason: nil,
        ts_error_reason: nil,
        ts_port: nil,
        started_at: nil,
        metrics: %{bytes_received: 0, bytes_sent: 0},
        wg_retry_count: 0,
        ts_retry_count: 0
    }

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap}}
  end

  # Independent control callbacks
  @impl true
  def handle_call({:start_wg}, _from, state) do
    updated_state = %{state | wg_status: :starting, wg_error_reason: nil}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_wg}}
  end

  @impl true
  def handle_call({:stop_wg}, _from, state) do
    Logger.info("Stopping WireGuard for pair: #{state.id}")

    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{
      state
      | wg_status: :stopped,
        wg_error_reason: nil,
        started_at: nil,
        metrics: %{bytes_received: 0, bytes_sent: 0}
    }

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:restart_wg}, _from, state) do
    Logger.info("Restarting WireGuard for pair: #{state.id}")

    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{state | wg_status: :starting, wg_error_reason: nil}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_wg}}
  end

  @impl true
  def handle_call({:update_wg_config, new_wg_config}, _from, state) do
    Logger.info("Updating WireGuard config for pair: #{state.id}")

    updated_state = %{state | wg_config_content: new_wg_config}

    try do
      File.mkdir_p!(updated_state.storage_dir)
      resolved_content = resolve_endpoint_in_config(new_wg_config)
      File.write!(updated_state.wg_config_path, resolved_content)
      File.chmod!(updated_state.wg_config_path, 0o600)

      updated_state = broadcast_update(updated_state)

      if updated_state.wg_status in [:running, :starting] do
        state.outbound_module.cleanup(state.id, state.storage_dir)

        restarted_state = %{updated_state | wg_status: :starting, wg_error_reason: nil}
        restarted_state = broadcast_update(restarted_state)
        {:reply, {:ok, restarted_state}, restarted_state, {:continue, :bootstrap_wg}}
      else
        {:reply, {:ok, updated_state}, updated_state}
      end
    rescue
      e ->
        Logger.error("Failed to update WG config file: #{inspect(e)}")

        error_state = %{
          updated_state
          | wg_status: :error,
            wg_error_reason: "Config update setup failure: #{Exception.message(e)}"
        }

        error_state = broadcast_update(error_state)
        {:reply, {:error, Exception.message(e)}, error_state}
    end
  end

  @impl true
  def handle_call({:start_ts}, _from, state) do
    if not netns_exists?(state.wg_container_name) do
      {:reply, {:error, "Network namespace does not exist. WireGuard must be started first."},
       state}
    else
      updated_state = %{state | ts_status: :starting, ts_error_reason: nil}
      updated_state = broadcast_update(updated_state)
      {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
    end
  end

  @impl true
  def handle_call({:stop_ts}, _from, state) do
    Logger.info("Stopping Tailscale for pair: #{state.id}")

    if state.ts_port do
      Process.unlink(state.ts_port)
      Port.close(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{
      state
      | ts_status: :stopped,
        ts_error_reason: nil,
        ts_port: nil,
        started_at: nil
    }

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:restart_ts}, _from, state) do
    Logger.info("Restarting Tailscale for pair: #{state.id}")

    if state.ts_port do
      Process.unlink(state.ts_port)
      Port.close(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{state | ts_status: :starting, ts_error_reason: nil, ts_port: nil}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
  end

  # Health checking and metric polling

  @impl true
  def handle_info({:check_wg_health, retries}, state) do
    if state.ts_status == :starting do
      case state.outbound_module.get_status(state.id, state.storage_dir) do
        :running ->
          trigger_handshake("hermit_wg_#{state.id}")

          case state.outbound_module.get_metrics(state.id, state.storage_dir) do
            {:ok, %{bytes_received: bytes_received}} when bytes_received > 0 ->
              # Start Tailscale inside the network namespace
              case state.inbound_module.bootstrap(
                     state.id,
                     "wg0",
                     state.storage_dir,
                     state.inbound_config
                   ) do
                {:ok, port} ->
                  # Approve exit node in background Task so it doesn't block startup
                  Task.start(fn ->
                    state.inbound_module.approve_exit_node(state.id)
                  end)

                  running_state = %{
                    state
                    | ts_status: :running,
                      ts_error_reason: nil,
                      started_at: System.system_time(:second),
                      ts_port: port,
                      ts_retry_count: 0
                  }

                  updated_state = broadcast_update(running_state)
                  schedule_metrics_poll()
                  {:noreply, updated_state}

                {:error, reason} ->
                  error_state = %{
                    state
                    | ts_status: :error,
                      ts_error_reason: "Tailscale failed: #{inspect(reason)}"
                  }

                  updated_state = broadcast_update(error_state)
                  maybe_schedule_ts_recovery(updated_state)
                  {:noreply, updated_state}
              end

            _ ->
              retry_health_check(retries, state)
          end

        _ ->
          retry_health_check(retries, state)
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_metrics, state) do
    if state.wg_status == :running do
      case state.outbound_module.get_metrics(state.id, state.storage_dir) do
        {:ok, outbound_metrics} ->
          inbound_info = state.inbound_module.get_network_info(state.id, state.storage_dir)
          metrics = Map.merge(outbound_metrics, inbound_info)

          updated_state = %{state | metrics: metrics, wg_retry_count: 0}
          updated_state = broadcast_update(updated_state)
          schedule_metrics_poll()
          {:noreply, updated_state}

        _error ->
          # Get metrics failed. Check if outbound is actually down
          case state.outbound_module.get_status(state.id, state.storage_dir) do
            :running ->
              # Outbound is still running, maybe a temporary failure
              schedule_metrics_poll()
              {:noreply, state}

            _ ->
              # WG namespace is not running/exists!
              if state.status != :stopped do
                Logger.error(
                  "WireGuard namespace is down for pair #{state.id}. Triggering recovery..."
                )

                if state.ts_port do
                  Process.unlink(state.ts_port)
                  Port.close(state.ts_port)
                end

                state.inbound_module.cleanup(state.id, state.storage_dir)

                error_state = %{
                  state
                  | wg_status: :error,
                    ts_status: :stopped,
                    ts_port: nil,
                    started_at: nil,
                    wg_error_reason: "WireGuard namespace went down unexpectedly"
                }

                updated_state = broadcast_update(error_state)
                maybe_schedule_wg_recovery(updated_state)
                {:noreply, updated_state}
              else
                {:noreply, state}
              end
          end
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, reason}, state) when is_port(port) do
    if port == state.ts_port do
      Logger.error("Tailscale port for pair #{state.id} exited: #{inspect(reason)}")

      error_state = %{
        state
        | ts_status: :error,
          ts_error_reason: "Tailscale daemon exited unexpectedly: #{inspect(reason)}",
          ts_port: nil,
          started_at: nil
      }

      updated_state = broadcast_update(error_state)
      maybe_schedule_ts_recovery(updated_state)
      {:noreply, updated_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:recover_wg, state) do
    if state.status != :stopped and state.wg_status != :running do
      if state.wg_retry_count < 10 do
        Logger.info(
          "Recovering WireGuard for pair: #{state.id} (attempt #{state.wg_retry_count + 1})"
        )

        # Cleanup both inbound and outbound first
        state.inbound_module.cleanup(state.id, state.storage_dir)
        state.outbound_module.cleanup(state.id, state.storage_dir)

        updated_state = %{
          state
          | wg_status: :starting,
            ts_status: :starting,
            wg_error_reason: nil,
            ts_error_reason: nil,
            wg_retry_count: state.wg_retry_count + 1
        }

        updated_state = broadcast_update(updated_state)
        {:noreply, updated_state, {:continue, :bootstrap}}
      else
        Logger.error("Max WireGuard recovery retries reached for pair: #{state.id}")

        error_state = %{
          state
          | wg_status: :error,
            wg_error_reason: "Max recovery retries reached"
        }

        updated_state = broadcast_update(error_state)
        {:noreply, updated_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:recover_ts, state) do
    if state.status != :stopped and state.wg_status == :running and state.ts_status != :running do
      if state.ts_retry_count < 10 do
        Logger.info(
          "Recovering Tailscale for pair: #{state.id} (attempt #{state.ts_retry_count + 1})"
        )

        if state.ts_port do
          Process.unlink(state.ts_port)
          Port.close(state.ts_port)
        end

        state.inbound_module.cleanup(state.id, state.storage_dir)

        updated_state = %{
          state
          | ts_status: :starting,
            ts_error_reason: nil,
            ts_port: nil,
            ts_retry_count: state.ts_retry_count + 1
        }

        updated_state = broadcast_update(updated_state)
        {:noreply, updated_state, {:continue, :bootstrap_ts}}
      else
        Logger.error("Max Tailscale recovery retries reached for pair: #{state.id}")

        error_state = %{
          state
          | ts_status: :error,
            ts_error_reason: "Max recovery retries reached"
        }

        updated_state = broadcast_update(error_state)
        {:noreply, updated_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.info(
      "Received EXIT signal from #{inspect(pid)}, shutting down PairWorker #{state.id}. Reason: #{inspect(reason)}"
    )

    {:stop, reason, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning(
      "Terminating PairWorker #{state.id}. Performing forced cleanup. Reason: #{inspect(reason)}"
    )

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_deleted, state.id})

    if state.ts_port do
      Process.unlink(state.ts_port)
      Port.close(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)
    :ok
  end

  # --- Internal Helpers ---

  defp resolve_endpoint_in_config(content) do
    Regex.replace(
      ~r/^\s*Endpoint\s*=\s*(\[[^\]]+\]|[^:\s]+)\s*:\s*(\d+)/mi,
      content,
      fn full_match, host, port ->
        case resolve_host(host) do
          {:ok, ip_str} -> "Endpoint = #{ip_str}:#{port}"
          _ -> full_match
        end
      end
    )
  end

  defp resolve_host(host) do
    clean_host =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    charlist_host = String.to_charlist(clean_host)

    case :inet.getaddr(charlist_host, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple_to_string(ip_tuple)}

      _ ->
        case :inet.getaddr(charlist_host, :inet6) do
          {:ok, ip_tuple} -> {:ok, ip_tuple_to_string(ip_tuple)}
          error -> error
        end
    end
  end

  defp ip_tuple_to_string(ip_tuple) when tuple_size(ip_tuple) == 8 do
    ip_str = ip_tuple |> :inet.ntoa() |> List.to_string()
    "[#{ip_str}]"
  end

  defp ip_tuple_to_string(ip_tuple) do
    ip_tuple |> :inet.ntoa() |> List.to_string()
  end

  defp get_storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  defp trigger_handshake(wg_name) do
    if not mock?() do
      # Run a quick, non-blocking / short-timeout curl inside the namespace to trigger handshake.
      # We ignore the exit code/result because we only care about the packet being sent.
      # Using 1.1.1.1 is standard, fast, and does not require DNS.
      # We run this asynchronously using Task.start/1 to prevent blocking the worker.
      Task.start(fn ->
        System.cmd("ip", [
          "netns",
          "exec",
          wg_name,
          "curl",
          "-s",
          "-o",
          "/dev/null",
          "--max-time",
          "1",
          "http://1.1.1.1"
        ])
      end)
    end
  end

  defp netns_exists?(ns_name) do
    if mock?() do
      storage_dir = Path.join(get_storage_base_path(), String.replace(ns_name, "hermit_wg_", ""))
      File.exists?(storage_dir)
    else
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
  end

  defp retry_health_check(0, state) do
    Logger.error("WireGuard tunnel handshake timeout for pair: #{state.id}")
    error_state = %{state | ts_status: :error, ts_error_reason: "WireGuard handshake timeout"}
    updated_state = broadcast_update(error_state)
    maybe_schedule_ts_recovery(updated_state)
    {:noreply, updated_state}
  end

  defp retry_health_check(retries, state) do
    Process.send_after(self(), {:check_wg_health, retries - 1}, 1000)
    {:noreply, state}
  end

  defp schedule_metrics_poll do
    Process.send_after(self(), :poll_metrics, 3000)
  end

  defp maybe_schedule_wg_recovery(state) do
    if state.status != :stopped do
      Logger.info("Scheduling WireGuard recovery for pair #{state.id} in 5 seconds...")
      Process.send_after(self(), :recover_wg, 5000)
    end
  end

  defp maybe_schedule_ts_recovery(state) do
    if state.status != :stopped and state.wg_status == :running do
      Logger.info("Scheduling Tailscale recovery for pair #{state.id} in 5 seconds...")
      Process.send_after(self(), :recover_ts, 5000)
    end
  end

  defp broadcast_update(state) do
    # Calculate legacy overall status and error_reason
    {overall_status, error_reason} =
      cond do
        state.wg_status == :error ->
          {:error, state.wg_error_reason}

        state.ts_status == :error ->
          {:error, state.ts_error_reason}

        state.wg_status == :running and state.ts_status == :running ->
          {:running, nil}

        state.wg_status == :starting ->
          {:starting_wg, nil}

        state.ts_status == :starting ->
          {:starting_ts, nil}

        state.wg_status == :stopped and state.ts_status == :stopped ->
          {:stopped, nil}

        true ->
          {:stopped, nil}
      end

    updated_state = %{state | status: overall_status, error_reason: error_reason}

    update_db_status(
      updated_state.id,
      to_string(updated_state.wg_status),
      to_string(updated_state.ts_status),
      updated_state.wg_error_reason,
      updated_state.ts_error_reason,
      to_string(overall_status),
      updated_state.started_at
    )

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_updated, updated_state})

    updated_state
  end

  defp update_db_status(id, wg_status, ts_status, wg_err, ts_err, overall_status, started_at) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        :ok

      pair ->
        pair
        |> Hermit.Vpn.VpnPair.changeset(%{
          status: overall_status,
          wg_status: wg_status,
          ts_status: ts_status,
          wg_error_reason: wg_err,
          ts_error_reason: ts_err,
          started_at: started_at
        })
        |> Hermit.Repo.update()
    end
  rescue
    _ -> :ok
  end
end
