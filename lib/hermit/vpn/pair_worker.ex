defmodule Hermit.Vpn.PairWorker do
  use GenServer, restart: :transient
  require Logger

  @topic "vpn_pairs"

  @default_metrics %{
    bytes_received: 0,
    bytes_sent: 0,
    ts_ips: [],
    ts_backend_state: "Offline",
    ts_user: "Unknown",
    ts_magic_dns: "",
    ts_exit_node: false,
    wg_port: nil,
    latency: nil
  }

  defstruct [
    :id,
    :wg_container_name,
    :ts_container_name,
    :wg_config_path,
    :wg_config_content,
    :ts_auth_key,
    :status,
    :error_reason,
    :wg_status,
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
    outbound_config: nil,
    inbound_type: "tailscale",
    metrics_timer: nil,
    outbound_if: "wg0",
    bootstrap_task: nil,
    current_ping_task: nil,
    latency_last_checked_at: 0,
    last_db_state: nil
  ]

  # --- Client API ---

  def start_link(args) do
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
          outbound_config = pair.outbound_config || %{}
          updated_outbound_config = Map.put(outbound_config, "wg_config", new_wg_config)

          case pair
               |> Hermit.Vpn.VpnPair.changeset(%{outbound_config: updated_outbound_config})
               |> Hermit.Repo.update() do
            {:ok, _} ->
              case GenServer.whereis(via_tuple(id)) do
                nil ->
                  case ensure_worker_running(id) do
                    {:ok, pid} -> GenServer.call(pid, {:update_wg_config, new_wg_config})
                    _ -> {:ok, :updated_offline}
                  end

                pid ->
                  GenServer.call(pid, {:update_wg_config, new_wg_config})
              end

            {:error, changeset} ->
              {:error, changeset}
          end
        end
    end
  end

  def update_inbound_config(id, new_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        case pair
             |> Hermit.Vpn.VpnPair.changeset(%{inbound_config: new_config})
             |> Hermit.Repo.update() do
          {:ok, updated_pair} ->
            deduplicate_domains(id, updated_pair.inbound_config, pair.inbound_profile_id)

            case GenServer.whereis(via_tuple(id)) do
              nil ->
                case ensure_worker_running(id) do
                  {:ok, pid} ->
                    GenServer.call(pid, {:update_inbound_config, updated_pair.inbound_config})

                  _ ->
                    {:ok, :updated_offline}
                end

              pid ->
                GenServer.call(pid, {:update_inbound_config, updated_pair.inbound_config})
            end

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def update_outbound_config(id, new_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        case pair
             |> Hermit.Vpn.VpnPair.changeset(%{outbound_config: new_config})
             |> Hermit.Repo.update() do
          {:ok, updated_pair} ->
            # Extracted WireGuard config string from outbound_config
            wg_cfg =
              Map.get(updated_pair.outbound_config, "wg_config") ||
                Map.get(updated_pair.outbound_config, :wg_config) || ""

            case GenServer.whereis(via_tuple(id)) do
              nil ->
                case ensure_worker_running(id) do
                  {:ok, pid} ->
                    GenServer.call(pid, {:update_wg_config, wg_cfg})
                    GenServer.call(pid, {:update_outbound_config, updated_pair.outbound_config})

                  _ ->
                    {:ok, :updated_offline}
                end

              pid ->
                GenServer.call(pid, {:update_wg_config, wg_cfg})
                GenServer.call(pid, {:update_outbound_config, updated_pair.outbound_config})
            end

          {:error, changeset} ->
            {:error, changeset}
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

    registry_ids =
      Registry.select(Hermit.Vpn.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.filter(fn
        key when is_binary(key) -> not String.starts_with?(key, "ui_session:")
        _ -> false
      end)

    all_ids = Enum.uniq(persisted_ids ++ registry_ids)

    Enum.map(all_ids, fn id ->
      case GenServer.whereis(via_tuple(id)) do
        nil ->
          pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)

          {inbound_type, inbound_config} =
            cond do
              pair && pair.inbound_config && map_size(pair.inbound_config) > 0 ->
                sanitized = sanitize_inbound_config(id, pair.inbound_config)
                {pair.inbound_type || "tailscale", sanitized}

              pair && pair.inbound_profile ->
                sanitized = sanitize_inbound_config(id, pair.inbound_profile.config || %{})
                {pair.inbound_profile.type, sanitized}

              true ->
                {"tailscale", %{}}
            end

          {outbound_type, outbound_config} =
            cond do
              pair && pair.outbound_config && map_size(pair.outbound_config) > 0 ->
                {pair.outbound_type || "wireguard", pair.outbound_config}

              pair && pair.outbound_profile ->
                {pair.outbound_profile.type, pair.outbound_profile.config || %{}}

              true ->
                {"wireguard", %{}}
            end

          inbound_mod =
            case inbound_type do
              "tailscale" -> Hermit.Vpn.Inbound.Tailscale
              "proxy" -> Hermit.Vpn.Inbound.Proxy
              _ -> Hermit.Vpn.Inbound.Tailscale
            end

          outbound_mod =
            case outbound_type do
              "wireguard" -> Hermit.Vpn.Outbound.WireGuard
              "local" -> Hermit.Vpn.Outbound.Local
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
            metrics: @default_metrics,
            storage_dir: Path.join(get_storage_base_path(), id),
            started_at: pair && pair.started_at,
            ts_port: nil,
            inbound_module: inbound_mod,
            outbound_module: outbound_mod,
            inbound_config: inbound_config,
            outbound_config: outbound_config,
            inbound_type: inbound_type
          }

        pid ->
          try do
            GenServer.call(pid, :get_state, 1000)
          catch
            _, _ ->
              pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)

              {inbound_type, inbound_config} =
                cond do
                  pair && pair.inbound_config && map_size(pair.inbound_config) > 0 ->
                    {pair.inbound_type || "tailscale", pair.inbound_config}

                  pair && pair.inbound_profile ->
                    {pair.inbound_profile.type, pair.inbound_profile.config || %{}}

                  true ->
                    {"tailscale", %{}}
                end

              {outbound_type, outbound_config} =
                cond do
                  pair && pair.outbound_config && map_size(pair.outbound_config) > 0 ->
                    {pair.outbound_type || "wireguard", pair.outbound_config}

                  pair && pair.outbound_profile ->
                    {pair.outbound_profile.type, pair.outbound_profile.config || %{}}

                  true ->
                    {"wireguard", %{}}
                end

              inbound_mod =
                case inbound_type do
                  "tailscale" -> Hermit.Vpn.Inbound.Tailscale
                  "proxy" -> Hermit.Vpn.Inbound.Proxy
                  _ -> Hermit.Vpn.Inbound.Tailscale
                end

              outbound_mod =
                case outbound_type do
                  "wireguard" -> Hermit.Vpn.Outbound.WireGuard
                  "local" -> Hermit.Vpn.Outbound.Local
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
                metrics: @default_metrics,
                storage_dir: Path.join(get_storage_base_path(), id),
                started_at: pair && pair.started_at,
                ts_port: nil,
                inbound_module: inbound_mod,
                outbound_module: outbound_mod,
                inbound_config: inbound_config,
                outbound_config: outbound_config,
                inbound_type: inbound_type
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
      try do
        case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
          nil ->
            {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
             args[:inbound_config] || %{"ts_auth_key" => args[:ts_auth_key]},
             args[:outbound_type] || "wireguard",
             args[:outbound_config] ||
               %{"wg_config" => args[:wg_config] || args[:wg_config_content]}}

          pair ->
            pair = Hermit.Repo.preload(pair, [:inbound_profile, :outbound_profile])

            {inbound_type, inbound_config} =
              cond do
                pair.inbound_config && map_size(pair.inbound_config) > 0 ->
                  sanitized = sanitize_inbound_config(id, pair.inbound_config)
                  {pair.inbound_type || "tailscale", sanitized}

                pair.inbound_profile ->
                  sanitized = sanitize_inbound_config(id, pair.inbound_profile.config || %{})
                  save_inbound_config_db(pair, sanitized)
                  {pair.inbound_profile.type, sanitized}

                true ->
                  {"tailscale", %{}}
              end

            {outbound_type, outbound_config} =
              cond do
                pair.outbound_config && map_size(pair.outbound_config) > 0 ->
                  {pair.outbound_type || "wireguard", pair.outbound_config}

                pair.outbound_profile ->
                  cfg = pair.outbound_profile.config || %{}
                  save_outbound_config_db(pair, cfg)
                  {pair.outbound_profile.type, cfg}

                true ->
                  {"wireguard", %{}}
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
      rescue
        e ->
          Logger.error("Failed to load VPN pair state from database during init: #{inspect(e)}")

          {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
           args[:inbound_config] || %{"ts_auth_key" => args[:ts_auth_key]},
           args[:outbound_type] || "wireguard",
           args[:outbound_config] ||
             %{"wg_config" => args[:wg_config] || args[:wg_config_content]}}
      end

    inbound_module =
      case inbound_type do
        "tailscale" -> Hermit.Vpn.Inbound.Tailscale
        "proxy" -> Hermit.Vpn.Inbound.Proxy
        _ -> Hermit.Vpn.Inbound.Tailscale
      end

    outbound_module =
      case outbound_type do
        "wireguard" -> Hermit.Vpn.Outbound.WireGuard
        "local" -> Hermit.Vpn.Outbound.Local
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

    last_db_state = %{
      status: overall_status,
      wg_status: wg_status,
      ts_status: ts_status,
      wg_error_reason: nil,
      ts_error_reason: nil,
      started_at: started_at
    }

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
      metrics: @default_metrics,
      storage_dir: storage_dir,
      started_at: started_at,
      ts_port: nil,
      ts_retry_count: 0,
      wg_retry_count: 0,
      inbound_module: inbound_module,
      outbound_module: outbound_module,
      inbound_config: inbound_config,
      outbound_config: outbound_config,
      inbound_type: inbound_type,
      last_db_state: last_db_state
    }

    cond do
      wg_status == :starting and ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap}}

      wg_status == :starting ->
        {:ok, state, {:continue, :bootstrap_wg}}

      ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap_ts}}

      true ->
        state =
          if wg_status == :running do
            schedule_metrics_poll(state)
          else
            state
          end

        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    handle_continue(:bootstrap_wg, state)
  end

  @impl true
  def handle_continue(:pause_cleanup, state) do
    Logger.info("Running pause cleanup for VPN pair: #{state.id}")

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{state | ts_port: nil}
    updated_state = broadcast_update(updated_state)

    {:noreply, updated_state}
  end

  @impl true
  def handle_continue(:restart_cleanup, state) do
    Logger.info("Running restart cleanup for VPN pair: #{state.id}")

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)

    # Allow OS kernel to clean up netns and interfaces
    Process.sleep(1000)

    updated_state = %{state | ts_port: nil}
    updated_state = broadcast_update(updated_state)

    {:noreply, updated_state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:restart_wg_cleanup, state) do
    Logger.info("Running restart WG cleanup for VPN pair: #{state.id}")

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)

    # Allow OS kernel to clean up netns and interfaces
    Process.sleep(1000)

    updated_state = %{state | ts_port: nil}
    updated_state = broadcast_update(updated_state)

    {:noreply, updated_state, {:continue, :bootstrap_wg}}
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

      conflict_check =
        case Hermit.Repo.get(Hermit.Vpn.VpnPair, state.id) do
          nil -> :ok
          pair -> Hermit.Vpn.VpnPair.check_outbound_conflict(pair.outbound_profile_id, state.id)
        end

      case conflict_check do
        {:error, conflicting_id} ->
          error_state = %{
            state
            | wg_status: :error,
              wg_error_reason:
                "Outbound profile is already in use by active tunnel '#{conflicting_id}'."
          }

          updated_state = broadcast_update(error_state)
          {:noreply, updated_state}

        :ok ->
          case state.outbound_module.bootstrap(
                 state.id,
                 state.storage_dir,
                 state.outbound_config || %{}
               ) do
            {:ok, iface} ->
              updated_state = %{
                state
                | wg_status: :starting,
                  wg_error_reason: nil,
                  wg_retry_count: 0,
                  outbound_if: iface
              }

              updated_state = broadcast_update(updated_state)
              updated_state = schedule_metrics_poll(updated_state)

              send(self(), {:check_wg_health, 10})

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

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Pausing VPN pair (both components) asynchronously: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)

    updated_state =
      %{
        state
        | wg_status: :stopped,
          ts_status: :stopped,
          wg_error_reason: nil,
          ts_error_reason: nil,
          started_at: nil,
          metrics: @default_metrics
      }
      |> cancel_metrics_poll()

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :pause_cleanup}}
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
    Logger.info("Restarting VPN pair (both components) asynchronously: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)

    updated_state =
      %{
        state
        | wg_status: :starting,
          ts_status: :starting,
          wg_error_reason: nil,
          ts_error_reason: nil,
          started_at: nil,
          metrics: @default_metrics,
          wg_retry_count: 0,
          ts_retry_count: 0
      }
      |> cancel_metrics_poll()

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :restart_cleanup}}
  end

  @impl true
  def handle_call({:start_wg}, _from, state) do
    updated_state = %{state | wg_status: :starting, wg_error_reason: nil}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_wg}}
  end

  @impl true
  def handle_call({:stop_wg}, _from, state) do
    Logger.info("Stopping WireGuard for pair: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state =
      %{
        state
        | wg_status: :stopped,
          ts_status: :stopped,
          wg_error_reason: nil,
          ts_error_reason: nil,
          ts_port: nil,
          started_at: nil,
          metrics: @default_metrics
      }
      |> cancel_metrics_poll()

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:restart_wg}, _from, state) do
    Logger.info("Restarting WireGuard for pair: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)

    updated_state =
      %{
        state
        | wg_status: :starting,
          ts_status: :starting,
          wg_error_reason: nil,
          ts_error_reason: nil,
          started_at: nil,
          wg_retry_count: 0,
          ts_retry_count: 0,
          metrics: @default_metrics
      }
      |> cancel_metrics_poll()

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :restart_wg_cleanup}}
  end

  @impl true
  def handle_call({:update_wg_config, new_wg_config}, _from, state) do
    Logger.info("Updating WireGuard config for pair: #{state.id}")

    updated_state = %{state | wg_config_content: new_wg_config}
    updated_state = maybe_shutdown_bootstrap_task(updated_state)

    try do
      File.mkdir_p!(updated_state.storage_dir)
      resolved_content = resolve_endpoint_in_config(new_wg_config)
      File.write!(updated_state.wg_config_path, resolved_content)
      File.chmod!(updated_state.wg_config_path, 0o600)

      updated_state = broadcast_update(updated_state)

      if updated_state.wg_status in [:running, :starting] do
        if state.ts_port do
          stop_inbound_process(state.ts_port)
        end

        state.inbound_module.cleanup(state.id, state.storage_dir)
        state.outbound_module.cleanup(state.id, state.storage_dir)

        new_ts_status =
          if updated_state.ts_status in [:running, :starting] do
            :starting
          else
            updated_state.ts_status
          end

        restarted_state =
          %{
            updated_state
            | wg_status: :starting,
              ts_status: new_ts_status,
              ts_port: nil,
              wg_error_reason: nil,
              ts_error_reason: nil
          }
          |> cancel_metrics_poll()

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
  def handle_call({:update_outbound_config, new_config}, _from, state) do
    Logger.info("Updating outbound config for pair: #{state.id}")

    new_wg_config =
      Map.get(new_config, "wg_config") || Map.get(new_config, :wg_config) ||
        state.wg_config_content

    updated_state = %{
      state
      | outbound_config: new_config,
        wg_config_content: new_wg_config
    }

    updated_state = maybe_shutdown_bootstrap_task(updated_state)

    try do
      File.mkdir_p!(updated_state.storage_dir)
      resolved_content = resolve_endpoint_in_config(new_wg_config)
      File.write!(updated_state.wg_config_path, resolved_content)
      File.chmod!(updated_state.wg_config_path, 0o600)

      updated_state = broadcast_update(updated_state)

      if updated_state.wg_status in [:running, :starting] do
        if state.ts_port do
          stop_inbound_process(state.ts_port)
        end

        state.inbound_module.cleanup(state.id, state.storage_dir)
        state.outbound_module.cleanup(state.id, state.storage_dir)

        new_ts_status =
          if updated_state.ts_status in [:running, :starting] do
            :starting
          else
            updated_state.ts_status
          end

        restarted_state =
          %{
            updated_state
            | wg_status: :starting,
              ts_status: new_ts_status,
              ts_port: nil,
              wg_error_reason: nil,
              ts_error_reason: nil
          }
          |> cancel_metrics_poll()

        restarted_state = broadcast_update(restarted_state)
        {:reply, {:ok, restarted_state}, restarted_state, {:continue, :bootstrap_wg}}
      else
        {:reply, {:ok, updated_state}, updated_state}
      end
    rescue
      e ->
        Logger.error("Failed to update Outbound config file: #{inspect(e)}")

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
  def handle_call({:set_inbound_config, new_config}, _from, state) do
    updated_state = %{state | inbound_config: new_config}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:update_inbound_config, new_config}, _from, state) do
    updated_state = %{state | inbound_config: new_config}
    updated_state = broadcast_update(updated_state)

    if state.ts_status == :running do
      parent = self()

      Task.start(fn ->
        case state.inbound_module.update_settings(state.id, new_config) do
          {:ok, _} ->
            state.inbound_module.approve_exit_node(state.id)
            send(parent, {:inbound_config_updated, new_config})

          :ok ->
            state.inbound_module.approve_exit_node(state.id)
            send(parent, {:inbound_config_updated, new_config})

          {:error, reason} ->
            Logger.error("Failed to dynamically update Tailscale settings: #{inspect(reason)}")
            send(parent, {:inbound_config_update_failed, reason})
        end
      end)

      {:reply, {:ok, updated_state}, updated_state}
    else
      {:reply, {:ok, updated_state}, updated_state}
    end
  end

  @impl true
  def handle_call({:start_ts}, _from, state) do
    cond do
      state.wg_status != :running ->
        {:reply,
         {:error, "WireGuard is not running. Outbound connection must be established first."},
         state}

      not netns_exists?(state.wg_container_name) ->
        {:reply, {:error, "Network namespace does not exist. WireGuard must be started first."},
         state}

      true ->
        updated_state = %{state | ts_status: :starting, ts_error_reason: nil}
        updated_state = broadcast_update(updated_state)
        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
    end
  end

  @impl true
  def handle_call({:stop_ts}, _from, state) do
    Logger.info("Stopping Tailscale for pair: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)

    if state.ts_port do
      stop_inbound_process(state.ts_port)
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
    cond do
      state.wg_status != :running ->
        {:reply,
         {:error, "WireGuard is not running. Outbound connection must be established first."},
         state}

      not netns_exists?(state.wg_container_name) ->
        {:reply, {:error, "Network namespace does not exist. WireGuard must be started first."},
         state}

      true ->
        Logger.info("Restarting Tailscale for pair: #{state.id}")

        state = maybe_shutdown_bootstrap_task(state)

        if state.ts_port do
          stop_inbound_process(state.ts_port)
        end

        state.inbound_module.cleanup(state.id, state.storage_dir)

        updated_state = %{state | ts_status: :starting, ts_error_reason: nil, ts_port: nil}
        updated_state = broadcast_update(updated_state)
        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
    end
  end

  @impl true
  def handle_info({:inbound_config_updated, _new_config}, state) do
    if state.ts_error_reason || state.ts_status == :error do
      updated_state = %{state | ts_error_reason: nil, ts_status: :running}
      updated_state = broadcast_update(updated_state)
      {:noreply, updated_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:inbound_config_update_failed, reason}, state) do
    error_state = %{
      state
      | ts_status: :error,
        ts_error_reason: "Failed to dynamically update Tailscale settings: #{inspect(reason)}"
    }

    updated_state = broadcast_update(error_state)
    {:noreply, updated_state}
  end

  # Health checking and metric polling

  @impl true
  def handle_info({:check_wg_health, retries}, state) do
    case state.outbound_module.get_status(state.id, state.storage_dir) do
      :running ->
        trigger_handshake("hermit_wg_#{state.id}")

        case state.outbound_module.get_metrics(state.id, state.storage_dir) do
          {:ok, %{bytes_received: bytes_received}}
          when bytes_received > 0 or state.outbound_module == Hermit.Vpn.Outbound.Local ->
            state =
              if state.wg_status != :running do
                %{state | wg_status: :running, wg_error_reason: nil}
                |> broadcast_update()
              else
                state
              end

            if state.ts_status == :starting do
              if state.bootstrap_task do
                {:noreply, state}
              else
                parent = self()
                id = state.id
                outbound_if = state.outbound_if || "wg0"
                storage_dir = state.storage_dir
                inbound_config = state.inbound_config
                inbound_module = state.inbound_module

                {:ok, task_pid} =
                  Task.start(fn ->
                    res = inbound_module.bootstrap(id, outbound_if, storage_dir, inbound_config)

                    case res do
                      {:ok, port_or_pid} ->
                        if is_port(port_or_pid) do
                          try do
                            Port.connect(port_or_pid, parent)
                            send(parent, {:bootstrap_result, self(), {:ok, port_or_pid}})
                          rescue
                            ArgumentError ->
                              send(parent, {:bootstrap_result, self(), {:error, :port_closed}})
                          end
                        else
                          Process.unlink(port_or_pid)
                          send(parent, {:bootstrap_result, self(), {:ok, port_or_pid}})
                        end

                      other ->
                        send(parent, {:bootstrap_result, self(), other})
                    end
                  end)

                ref = Process.monitor(task_pid)
                new_state = %{state | bootstrap_task: %{pid: task_pid, ref: ref}}
                {:noreply, new_state}
              end
            else
              {:noreply, state}
            end

          _ ->
            retry_health_check(retries, state)
        end

      _ ->
        retry_health_check(retries, state)
    end
  end

  @impl true
  def handle_info({:bootstrap_result, task_pid, result}, state) do
    if state.bootstrap_task && state.bootstrap_task.pid == task_pid do
      Process.demonitor(state.bootstrap_task.ref, [:flush])
      handle_bootstrap_result(result, %{state | bootstrap_task: nil})
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _task_pid, reason}, state) do
    cond do
      state.bootstrap_task && state.bootstrap_task.ref == ref ->
        Logger.error(
          "Bootstrap task for pair #{state.id} crashed or exited prematurely: #{inspect(reason)}"
        )

        handle_bootstrap_result(
          {:error, {:bootstrap_crashed, reason}},
          %{state | bootstrap_task: nil}
        )

      state.current_ping_task && state.current_ping_task.ref == ref ->
        metrics = Map.put(state.metrics || %{}, :latency, :error)
        updated_state = %{state | metrics: metrics, current_ping_task: nil}
        updated_state = broadcast_update(updated_state)
        {:noreply, updated_state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, latency}, state) do
    if state.current_ping_task && state.current_ping_task.ref == ref do
      Process.demonitor(ref, [:flush])
      metrics = Map.put(state.metrics || %{}, :latency, latency)
      updated_state = %{state | metrics: metrics, current_ping_task: nil}
      updated_state = broadcast_update(updated_state)
      {:noreply, updated_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_metrics, state) do
    if state.wg_status == :running do
      case state.outbound_module.get_metrics(state.id, state.storage_dir) do
        {:ok, outbound_metrics} ->
          inbound_info =
            if should_poll_inbound?(state) do
              info = state.inbound_module.get_network_info(state.id, state.storage_dir)
              Map.put(info, :inbound_fetched_at, System.system_time(:second))
            else
              Map.take(state.metrics || %{}, [
                :ts_ips,
                :ts_backend_state,
                :ts_user,
                :ts_magic_dns,
                :ts_exit_node,
                :proxy_port,
                :proxy_socks5_url,
                :proxy_http_url,
                :proxy_status,
                :inbound_fetched_at
              ])
            end

          metrics = Map.merge(outbound_metrics, inbound_info)

          # Preserve existing latency in the new metrics map
          existing_latency = Map.get(state.metrics || %{}, :latency)
          metrics = Map.put(metrics, :latency, existing_latency)

          now = System.system_time(:second)

          state =
            if has_active_ui?() and is_nil(state.current_ping_task) and
                 now - state.latency_last_checked_at >= 30 do
              task =
                Task.async(fn ->
                  measure_ping(state.outbound_module, state.id)
                end)

              %{state | current_ping_task: task, latency_last_checked_at: now}
            else
              state
            end

          updated_state = %{state | metrics: metrics, wg_retry_count: 0}
          updated_state = broadcast_update(updated_state)
          updated_state = schedule_metrics_poll(updated_state)
          {:noreply, updated_state}

        _error ->
          case state.outbound_module.get_status(state.id, state.storage_dir) do
            :running ->
              updated_state = schedule_metrics_poll(state)
              {:noreply, updated_state}

            _ ->
              if state.status != :stopped do
                Logger.error(
                  "WireGuard namespace is down for pair #{state.id}. Triggering recovery..."
                )

                if state.ts_port do
                  stop_inbound_process(state.ts_port)
                end

                state.inbound_module.cleanup(state.id, state.storage_dir)

                error_state =
                  %{
                    state
                    | wg_status: :error,
                      ts_status: :stopped,
                      ts_port: nil,
                      started_at: nil,
                      wg_error_reason: "WireGuard namespace went down unexpectedly"
                  }
                  |> cancel_metrics_poll()

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
    cond do
      port == state.ts_port ->
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

      true ->
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

        state = maybe_shutdown_bootstrap_task(state)

        state.inbound_module.cleanup(state.id, state.storage_dir)

        state.outbound_module.cleanup(state.id, state.storage_dir)

        updated_state =
          %{
            state
            | wg_status: :starting,
              ts_status: :starting,
              wg_error_reason: nil,
              ts_error_reason: nil,
              wg_retry_count: state.wg_retry_count + 1
          }
          |> cancel_metrics_poll()

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

        state = maybe_shutdown_bootstrap_task(state)

        if state.ts_port do
          stop_inbound_process(state.ts_port)
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
    cond do
      pid == state.ts_port ->
        Logger.error("Inbound proxy PID for pair #{state.id} exited: #{inspect(reason)}")

        error_state = %{
          state
          | ts_status: :error,
            ts_error_reason: "Inbound proxy exited unexpectedly: #{inspect(reason)}",
            ts_port: nil,
            started_at: nil
        }

        updated_state = broadcast_update(error_state)
        maybe_schedule_ts_recovery(updated_state)
        {:noreply, updated_state}

      true ->
        if reason not in [:normal, :shutdown, :killed] do
          Logger.warning(
            "Received EXIT signal from auxiliary process #{inspect(pid)} for pair #{state.id} (not main inbound port). Reason: #{inspect(reason)}"
          )
        end

        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning(
      "Terminating PairWorker #{state.id}. Performing forced cleanup. Reason: #{inspect(reason)}"
    )

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_deleted, state.id})

    state = maybe_shutdown_bootstrap_task(state)

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)
    :ok
  end

  # --- Internal Helpers ---

  defp resolve_endpoint_in_config(nil), do: ""

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
      case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
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

    error_state = %{
      state
      | wg_status: :error,
        wg_error_reason: "WireGuard handshake timeout",
        ts_status: if(state.ts_status == :starting, do: :stopped, else: state.ts_status),
        ts_error_reason: nil
    }

    updated_state = broadcast_update(error_state)
    maybe_schedule_wg_recovery(updated_state)
    updated_state = schedule_metrics_poll(updated_state)
    {:noreply, updated_state}
  end

  defp retry_health_check(retries, state) do
    Process.send_after(self(), {:check_wg_health, retries - 1}, 1000)
    {:noreply, state}
  end

  defp schedule_metrics_poll(state) do
    if state.metrics_timer do
      Process.cancel_timer(state.metrics_timer)
    end

    timer = Process.send_after(self(), :poll_metrics, 3000)
    %{state | metrics_timer: timer}
  end

  defp cancel_metrics_poll(state) do
    if state.metrics_timer do
      Process.cancel_timer(state.metrics_timer)
    end

    state = %{state | metrics_timer: nil}
    cancel_ping_task(state)
  end

  defp cancel_ping_task(state) do
    if state.current_ping_task do
      Process.demonitor(state.current_ping_task.ref, [:flush])
      Task.shutdown(state.current_ping_task, :brutal_kill)
    end

    %{state | current_ping_task: nil}
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

    db_changed? =
      is_nil(state.last_db_state) or
        state.last_db_state.status != overall_status or
        state.last_db_state.wg_status != state.wg_status or
        state.last_db_state.ts_status != state.ts_status or
        state.last_db_state.wg_error_reason != state.wg_error_reason or
        state.last_db_state.ts_error_reason != state.ts_error_reason or
        state.last_db_state.started_at != state.started_at

    state_with_db =
      if db_changed? do
        update_db_status(
          updated_state.id,
          to_string(updated_state.wg_status),
          to_string(updated_state.ts_status),
          updated_state.wg_error_reason,
          updated_state.ts_error_reason,
          to_string(overall_status),
          updated_state.started_at
        )

        new_last_db_state = %{
          status: overall_status,
          wg_status: state.wg_status,
          ts_status: state.ts_status,
          wg_error_reason: state.wg_error_reason,
          ts_error_reason: state.ts_error_reason,
          started_at: state.started_at
        }

        %{updated_state | last_db_state: new_last_db_state}
      else
        updated_state
      end

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_updated, state_with_db})

    state_with_db
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

  defp stop_inbound_process(nil), do: :ok

  defp stop_inbound_process(port_or_pid) do
    Process.unlink(port_or_pid)

    if is_port(port_or_pid) do
      try do
        Port.close(port_or_pid)
      rescue
        _ -> :ok
      end
    else
      try do
        GenServer.stop(port_or_pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp should_poll_inbound?(state) do
    now = System.system_time(:second)
    last_poll = Map.get(state.metrics || %{}, :inbound_fetched_at, 0)

    now - last_poll >= 300 or not has_inbound_info?(state.metrics || %{}, state.inbound_module)
  end

  defp has_inbound_info?(metrics, Hermit.Vpn.Inbound.Tailscale) do
    metrics[:ts_ips] != [] and metrics[:ts_backend_state] == "Running"
  end

  defp has_inbound_info?(metrics, Hermit.Vpn.Inbound.Proxy) do
    metrics[:proxy_port] != nil and metrics[:proxy_status] == "Running"
  end

  defp has_inbound_info?(_metrics, _module), do: false

  defp has_active_ui? do
    try do
      Registry.select(Hermit.Vpn.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.any?(fn
        key when is_binary(key) -> String.starts_with?(key, "ui_session:")
        _ -> false
      end)
    rescue
      _ -> false
    end
  end

  defp sanitize_inbound_config(pair_id, config) when is_map(config) do
    string_config = Map.new(config, fn {k, v} -> {to_string(k), v} end)
    tag = Map.get(string_config, "advertise_connector_tag")
    normalized_id = String.replace(pair_id, "_", "-")
    default_tag = "tag:connector-#{normalized_id}"

    resolved_tag =
      if is_binary(tag) and String.trim(tag) != "" do
        tag = String.trim(tag)

        case Regex.run(~r/^tag:connector-(.+)$/, tag) do
          [_, other_id] when other_id != normalized_id ->
            default_tag

          _ ->
            tag
        end
      else
        default_tag
      end

    put_config_value(config, "advertise_connector_tag", resolved_tag)
  end

  defp sanitize_inbound_config(_pair_id, config), do: config

  defp put_config_value(config, key, value) do
    cond do
      Map.has_key?(config, key) -> Map.put(config, key, value)
      Map.has_key?(config, String.to_atom(key)) -> Map.put(config, String.to_atom(key), value)
      true -> Map.put(config, key, value)
    end
  end

  defp save_inbound_config_db(pair, config) do
    pair
    |> Hermit.Vpn.VpnPair.changeset(%{inbound_config: config})
    |> Hermit.Repo.update()
  rescue
    _ -> :ok
  end

  defp save_outbound_config_db(pair, config) do
    pair
    |> Hermit.Vpn.VpnPair.changeset(%{outbound_config: config})
    |> Hermit.Repo.update()
  rescue
    _ -> :ok
  end

  defp deduplicate_domains(id, new_config, profile_id) do
    advertise_connector =
      case Map.get(new_config, "advertise_connector") || Map.get(new_config, :advertise_connector) do
        true -> true
        "true" -> true
        _ -> false
      end

    new_domains = if advertise_connector, do: clean_connector_domains(new_config), else: []

    if advertise_connector and new_domains != [] do
      new_domains_down = Enum.map(new_domains, &String.downcase/1)

      import Ecto.Query

      other_pairs =
        Hermit.Repo.all(
          from(p in Hermit.Vpn.VpnPair,
            where: p.pair_id != ^id and p.inbound_profile_id == ^profile_id
          )
        )

      Enum.each(other_pairs, fn other_pair ->
        other_config = other_pair.inbound_config || %{}

        other_domains_str =
          Map.get(other_config, "advertise_connector_domains") ||
            Map.get(other_config, :advertise_connector_domains) || ""

        other_advertise =
          case Map.get(other_config, "advertise_connector") ||
                 Map.get(other_config, :advertise_connector) do
            true -> true
            "true" -> true
            _ -> false
          end

        if other_advertise and other_domains_str != "" do
          other_domains_list =
            other_domains_str
            |> String.split([",", "\n"])
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          updated_domains_list =
            Enum.reject(other_domains_list, fn d -> String.downcase(d) in new_domains_down end)

          if length(other_domains_list) != length(updated_domains_list) do
            updated_domains_str = Enum.join(updated_domains_list, "\n")

            updated_other_config =
              other_config
              |> Map.put("advertise_connector_domains", updated_domains_str)

            other_pair
            |> Hermit.Vpn.VpnPair.changeset(%{inbound_config: updated_other_config})
            |> Hermit.Repo.update!()

            case GenServer.whereis(via_tuple(other_pair.pair_id)) do
              nil -> :ok
              pid -> GenServer.call(pid, {:set_inbound_config, updated_other_config})
            end
          end
        end
      end)
    end
  end

  defp clean_connector_domains(config) do
    domains_str =
      Map.get(config, "advertise_connector_domains") ||
        Map.get(config, :advertise_connector_domains) || ""

    if is_binary(domains_str) do
      domains_str
      |> String.split([",", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end

  defp maybe_shutdown_bootstrap_task(state) do
    if state.bootstrap_task do
      Logger.info("Shutting down active bootstrap task for pair #{state.id}")
      Process.demonitor(state.bootstrap_task.ref, [:flush])
      Process.exit(state.bootstrap_task.pid, :kill)
      %{state | bootstrap_task: nil}
    else
      state
    end
  end

  defp handle_bootstrap_result(result, state) do
    case result do
      {:ok, port} ->
        unless is_port(port) do
          Process.link(port)
        end

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
        updated_state = schedule_metrics_poll(updated_state)
        {:noreply, updated_state}

      {:error, reason} ->
        error_state = %{
          state
          | ts_status: :error,
            ts_error_reason: "Tailscale failed: #{inspect(reason)}"
        }

        updated_state = broadcast_update(error_state)
        maybe_schedule_ts_recovery(updated_state)
        updated_state = schedule_metrics_poll(updated_state)
        {:noreply, updated_state}
    end
  end

  defp measure_ping(outbound_module, pair_id) do
    cond do
      mock?() ->
        :rand.uniform(60) + 20

      outbound_module == Hermit.Vpn.Outbound.Local ->
        :n_a

      true ->
        wg_name = "hermit_wg_#{pair_id}"

        case System.cmd(
               "ip",
               [
                 "netns",
                 "exec",
                 wg_name,
                 "curl",
                 "-o",
                 "/dev/null",
                 "-s",
                 "-w",
                 "%{time_connect}",
                 "--connect-timeout",
                 "2",
                 "http://1.1.1.1"
               ],
               stderr_to_stdout: false
             ) do
          {output, _exit_code} ->
            case Float.parse(String.trim(output)) do
              {val, _} when val > 0.0 -> round(val * 1000)
              _ -> :error
            end
        end
    end
  end
end
