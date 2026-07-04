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
    wg_port: nil
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
    :dns_config,
    :dns_socket,
    :dns_port_proc,
    ts_retry_count: 0,
    wg_retry_count: 0,
    inbound_module: Hermit.Vpn.Inbound.Tailscale,
    outbound_module: Hermit.Vpn.Outbound.WireGuard,
    inbound_config: nil,
    outbound_config: nil,
    inbound_type: "tailscale",
    metrics_timer: nil,
    outbound_if: "wg0"
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

  def update_dns_config(id, new_dns_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        case pair
             |> Hermit.Vpn.VpnPair.changeset(%{dns_config: new_dns_config})
             |> Hermit.Repo.update() do
          {:ok, updated_pair} ->
            case GenServer.whereis(via_tuple(id)) do
              nil ->
                {:ok, :updated_offline}

              pid ->
                GenServer.call(pid, {:update_dns_config, updated_pair.dns_config})
            end

          {:error, changeset} ->
            {:error, changeset}
        end
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
                      nil ->
                        case ensure_worker_running(id) do
                          {:ok, pid} -> GenServer.call(pid, {:update_wg_config, new_wg_config})
                          _ -> {:ok, :updated_offline}
                        end

                      pid ->
                        GenServer.call(pid, {:update_wg_config, new_wg_config})
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

  def update_inbound_config(id, new_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        if pair.inbound_profile_id do
          case Hermit.Repo.get(Hermit.Vpn.InboundProfile, pair.inbound_profile_id) do
            nil ->
              {:error, :profile_not_found}

            profile ->
              case profile
                   |> Hermit.Vpn.InboundProfile.changeset(%{config: new_config})
                   |> Hermit.Repo.update() do
                {:ok, updated_profile} ->
                  case GenServer.whereis(via_tuple(id)) do
                    nil ->
                      case ensure_worker_running(id) do
                        {:ok, pid} ->
                          GenServer.call(pid, {:update_inbound_config, updated_profile.config})

                        _ ->
                          {:ok, :updated_offline}
                      end

                    pid ->
                      GenServer.call(pid, {:update_inbound_config, updated_profile.config})
                  end

                {:error, changeset} ->
                  {:error, changeset}
              end
          end
        else
          {:error, :no_inbound_profile}
        end
    end
  end

  def update_outbound_config(id, new_config) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil ->
        {:error, :not_found}

      pair ->
        if pair.outbound_profile_id do
          case Hermit.Repo.get(Hermit.Vpn.OutboundProfile, pair.outbound_profile_id) do
            nil ->
              {:error, :profile_not_found}

            profile ->
              case profile
                   |> Hermit.Vpn.OutboundProfile.changeset(%{config: new_config})
                   |> Hermit.Repo.update() do
                {:ok, updated_profile} ->
                  case GenServer.whereis(via_tuple(id)) do
                    nil ->
                      case ensure_worker_running(id) do
                        {:ok, pid} ->
                          GenServer.call(pid, {:update_outbound_config, updated_profile.config})

                        _ ->
                          {:ok, :updated_offline}
                      end

                    pid ->
                      GenServer.call(pid, {:update_outbound_config, updated_profile.config})
                  end

                {:error, changeset} ->
                  {:error, changeset}
              end
          end
        else
          {:error, :no_outbound_profile}
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
            outbound_config: outbound_config,
            inbound_type: inbound_type,
            dns_config: pair && pair.dns_config
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
                outbound_config: outbound_config,
                inbound_type: inbound_type,
                dns_config: pair && pair.dns_config
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
     outbound_type, outbound_config, dns_config} =
      try do
        case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
          nil ->
            {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
             args[:inbound_config] || %{"ts_auth_key" => args[:ts_auth_key]},
             args[:outbound_type] || "wireguard",
             args[:outbound_config] ||
               %{"wg_config" => args[:wg_config] || args[:wg_config_content]},
             %{
               "enabled" => false,
               "block_ads" => false,
               "block_adult" => false,
               "upstream_dns" => "1.1.1.1, 8.8.8.8",
               "custom_rules" => []
             }}

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

            dns_c = pair.dns_config || %{
              "enabled" => false,
              "block_ads" => false,
              "block_adult" => false,
              "upstream_dns" => "1.1.1.1, 8.8.8.8",
              "custom_rules" => []
            }

            {
              String.to_atom(pair.wg_status || "stopped"),
              String.to_atom(pair.ts_status || "stopped"),
              String.to_atom(pair.status || "stopped"),
              pair.started_at,
              inbound_type,
              inbound_config,
              outbound_type,
              outbound_config,
              dns_c
            }
        end
      rescue
        e ->
          Logger.error("Failed to load VPN pair state from database during init: #{inspect(e)}")

          {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
           args[:inbound_config] || %{"ts_auth_key" => args[:ts_auth_key]},
           args[:outbound_type] || "wireguard",
           args[:outbound_config] ||
             %{"wg_config" => args[:wg_config] || args[:wg_config_content]},
           %{
             "enabled" => false,
             "block_ads" => false,
             "block_adult" => false,
             "upstream_dns" => "1.1.1.1, 8.8.8.8",
             "custom_rules" => []
           }}
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
      outbound_config: outbound_config,
      inbound_type: inbound_type,
      dns_config: dns_config,
      dns_socket: nil,
      dns_port_proc: nil
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
          dns_enabled = is_map(state.dns_config) and state.dns_config["enabled"] == true
          outbound_config_with_dns = Map.put(state.outbound_config || %{}, :dns_enabled, dns_enabled)

          case state.outbound_module.bootstrap(state.id, state.storage_dir, outbound_config_with_dns) do
            {:ok, iface} ->
              updated_state = %{
                state
                | wg_status: :running,
                  wg_error_reason: nil,
                  wg_retry_count: 0,
                  outbound_if: iface
              }

              updated_state = apply_dns_settings(updated_state)

              updated_state = broadcast_update(updated_state)
              updated_state = schedule_metrics_poll(updated_state)

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
    Logger.info("Pausing VPN pair (both components): #{state.id}")

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    state = stop_dns_daemon_if_running(state)
    state = close_dns_socket_if_open(state)

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

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    state = stop_dns_daemon_if_running(state)
    state = close_dns_socket_if_open(state)

    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state =
      %{
        state
        | wg_status: :starting,
          ts_status: :starting,
          wg_error_reason: nil,
          ts_error_reason: nil,
          ts_port: nil,
          started_at: nil,
          metrics: @default_metrics,
          wg_retry_count: 0,
          ts_retry_count: 0
      }
      |> cancel_metrics_poll()

    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_call({:update_dns_config, new_dns_config}, _from, state) do
    state = %{state | dns_config: new_dns_config}
    state = apply_dns_settings(state)
    updated_state = broadcast_update(state)
    {:reply, {:ok, updated_state}, updated_state}
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

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    state = stop_dns_daemon_if_running(state)
    state = close_dns_socket_if_open(state)

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

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    state = stop_dns_daemon_if_running(state)
    state = close_dns_socket_if_open(state)

    state.outbound_module.cleanup(state.id, state.storage_dir)

    updated_state =
      %{
        state
        | wg_status: :starting,
          ts_status: :starting,
          wg_error_reason: nil,
          ts_error_reason: nil,
          ts_port: nil,
          started_at: nil,
          wg_retry_count: 0,
          ts_retry_count: 0,
          metrics: @default_metrics
      }
      |> cancel_metrics_poll()

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

        restarted_state =
          %{updated_state | wg_status: :starting, wg_error_reason: nil}
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

    try do
      File.mkdir_p!(updated_state.storage_dir)
      resolved_content = resolve_endpoint_in_config(new_wg_config)
      File.write!(updated_state.wg_config_path, resolved_content)
      File.chmod!(updated_state.wg_config_path, 0o600)

      updated_state = broadcast_update(updated_state)

      if updated_state.wg_status in [:running, :starting] do
        state.outbound_module.cleanup(state.id, state.storage_dir)

        restarted_state =
          %{updated_state | wg_status: :starting, wg_error_reason: nil}
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
    Logger.info("Restarting Tailscale for pair: #{state.id}")

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    updated_state = %{state | ts_status: :starting, ts_error_reason: nil, ts_port: nil}
    updated_state = broadcast_update(updated_state)
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
  end

  @impl true
  def handle_info({:inbound_config_updated, _new_config}, state) do
    if state.ts_error_reason do
      updated_state = %{state | ts_error_reason: nil}
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
      | ts_error_reason: "Failed to dynamically update Tailscale settings: #{inspect(reason)}"
    }

    updated_state = broadcast_update(error_state)
    {:noreply, updated_state}
  end

  # Health checking and metric polling

  @impl true
  def handle_info({:check_wg_health, retries}, state) do
    if state.ts_status == :starting do
      case state.outbound_module.get_status(state.id, state.storage_dir) do
        :running ->
          trigger_handshake("hermit_wg_#{state.id}")

          case state.outbound_module.get_metrics(state.id, state.storage_dir) do
            {:ok, %{bytes_received: bytes_received}}
            when bytes_received > 0 or state.outbound_module == Hermit.Vpn.Outbound.Local ->
              case state.inbound_module.bootstrap(
                     state.id,
                     state.outbound_if || "wg0",
                     state.storage_dir,
                     state.inbound_config
                   ) do
                {:ok, port} ->
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

                state = stop_dns_daemon_if_running(state)
                state = close_dns_socket_if_open(state)

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

      port == state.dns_port_proc ->
        Logger.error("DNS proxy port for pair #{state.id} exited: #{inspect(reason)}")
        {:noreply, %{state | dns_port_proc: nil}}

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

        state.inbound_module.cleanup(state.id, state.storage_dir)

        state = stop_dns_daemon_if_running(state)
        state = close_dns_socket_if_open(state)

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

      pid == state.dns_port_proc ->
        Logger.warning("DNS mock log generator task exited: #{inspect(reason)}")
        {:noreply, %{state | dns_port_proc: nil}}

      true ->
        Logger.info(
          "Received EXIT signal from #{inspect(pid)}, shutting down PairWorker #{state.id}. Reason: #{inspect(reason)}"
        )

        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, packet}, %{dns_socket: socket} = state) do
    case Jason.decode(packet) do
      {:ok, log} ->
        counter = System.unique_integer([:monotonic])
        :ets.insert(:dns_query_logs, {{state.id, counter}, log})
        Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{state.id}", {:dns_log, log})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:mock_dns_log, log}, state) do
    counter = System.unique_integer([:monotonic])
    :ets.insert(:dns_query_logs, {{state.id, counter}, log})
    Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{state.id}", {:dns_log, log})
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning(
      "Terminating PairWorker #{state.id}. Performing forced cleanup. Reason: #{inspect(reason)}"
    )

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_deleted, state.id})

    if state.ts_port do
      stop_inbound_process(state.ts_port)
    end

    state = stop_dns_daemon_if_running(state)
    state = close_dns_socket_if_open(state)

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

    %{state | metrics_timer: nil}
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

  # --- DNS Filtering Management ---

  defp apply_dns_settings(state) do
    write_dns_rules(state)
    dns_enabled = is_map(state.dns_config) and state.dns_config["enabled"] == true

    if dns_enabled do
      state = ensure_dns_socket_open(state)
      write_netns_resolv_conf(state, ["127.0.0.1"])
      ensure_dns_daemon_running(state)
    else
      state = stop_dns_daemon_if_running(state)
      state = close_dns_socket_if_open(state)
      restore_original_resolv_conf(state)
      state
    end
  end

  defp write_dns_rules(state) do
    path = Path.join(state.storage_dir, "dns_rules.json")
    File.mkdir_p!(state.storage_dir)
    File.write!(path, Jason.encode!(state.dns_config || %{}))
  end

  defp ensure_dns_socket_open(%{dns_socket: nil} = state) do
    socket_path = Path.join(state.storage_dir, "dns_log.sock")
    File.rm(socket_path)
    File.mkdir_p!(state.storage_dir)
    case :gen_udp.open(0, [:binary, active: true, ifaddr: {:local, socket_path}]) do
      {:ok, socket} ->
        %{state | dns_socket: socket}
      {:error, reason} ->
        Logger.error("Failed to open Unix DNS log socket for pair #{state.id}: #{inspect(reason)}")
        state
    end
  end
  defp ensure_dns_socket_open(state), do: state

  defp close_dns_socket_if_open(%{dns_socket: socket} = state) when not is_nil(socket) do
    :gen_udp.close(socket)
    File.rm(Path.join(state.storage_dir, "dns_log.sock"))
    %{state | dns_socket: nil}
  end
  defp close_dns_socket_if_open(state), do: state

  defp write_netns_resolv_conf(state, dns_servers) do
    if not mock?() do
      netns_dns_dir = "/etc/netns/hermit_wg_#{state.id}"
      File.mkdir_p!(netns_dns_dir)
      dns_lines = dns_servers |> Enum.map(&"nameserver #{&1}") |> Enum.join("\n")
      File.write!(Path.join(netns_dns_dir, "resolv.conf"), dns_lines)
    end
    :ok
  end

  defp ensure_dns_daemon_running(%{dns_port_proc: nil} = state) do
    case start_dns_daemon(state) do
      {:ok, proc} ->
        %{state | dns_port_proc: proc}
      _ ->
        state
    end
  end
  defp ensure_dns_daemon_running(state), do: state

  defp stop_dns_daemon_if_running(%{dns_port_proc: proc} = state) when not is_nil(proc) do
    stop_dns_process(proc)
    %{state | dns_port_proc: nil}
  end
  defp stop_dns_daemon_if_running(state), do: state

  defp start_dns_daemon(state) do
    if mock?() do
      mock_log_task = start_mock_log_generator(state.id)
      {:ok, mock_log_task}
    else
      upstream = Map.get(state.dns_config || %{}, "upstream_dns") || "1.1.1.1, 8.8.8.8"
      rules_path = Path.join(state.storage_dir, "dns_rules.json")
      socket_path = Path.join(state.storage_dir, "dns_log.sock")
      
      args = [
        "netns", "exec", "hermit_wg_#{state.id}",
        "python3", "/app/priv/scripts/dns_server.py",
        "--id", state.id,
        "--upstream", upstream,
        "--rules", rules_path,
        "--log-socket", socket_path,
        "--port", "53"
      ]
      
      try do
        port = Port.open({:spawn_executable, "/usr/bin/ip"}, [:binary, args: args])
        Logger.info("DNS Proxy Daemon started inside netns for pair #{state.id}")
        {:ok, port}
      rescue
        e ->
          Logger.error("Failed to start DNS Proxy Daemon for pair #{state.id}: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  defp start_mock_log_generator(pair_id) do
    worker_pid = self()
    {:ok, task} = Task.start_link(fn ->
      mock_domains = [
        {"google.com", "A", "resolved", "142.250.190.46"},
        {"doubleclick.net", "A", "blocked", "NXDOMAIN"},
        {"netflix.com", "A", "redirected", "1.2.3.4"},
        {"facebook.com", "A", "resolved", "157.240.22.35"},
        {"pornhub.com", "AAAA", "blocked", "NXDOMAIN"},
        {"api.github.com", "A", "resolved", "140.82.121.5"}
      ]
      
      generator_loop(pair_id, worker_pid, mock_domains)
    end)
    task
  end

  defp generator_loop(pair_id, worker_pid, mock_domains) do
    Process.sleep(Enum.random(4000..8000))
    {domain, type, status, answer} = Enum.random(mock_domains)
    log = %{
      "pair_id" => pair_id,
      "domain" => domain,
      "type" => type,
      "status" => status,
      "answer" => answer,
      "duration" => Enum.random(5..120),
      "timestamp" => System.system_time(:second)
    }
    
    send(worker_pid, {:mock_dns_log, log})
    generator_loop(pair_id, worker_pid, mock_domains)
  end

  defp get_original_dns(state) do
    case state.outbound_config do
      %{"dns_servers" => list} when is_list(list) ->
        list
      _ ->
        case Regex.run(~r/^\s*DNS\s*=\s*([^\s#\n\r]+)/m, state.wg_config_content || "") do
          [_, dns] ->
            dns
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
          _ ->
            ["1.1.1.1"]
        end
    end
  end

  defp restore_original_resolv_conf(state) do
    write_netns_resolv_conf(state, get_original_dns(state))
  end

  defp stop_dns_process(nil), do: :ok
  defp stop_dns_process(port_or_pid) do
    Process.unlink(port_or_pid)

    if is_port(port_or_pid) do
      try do
        Port.close(port_or_pid)
      rescue
        _ -> :ok
      end
    else
      try do
        Process.exit(port_or_pid, :kill)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
