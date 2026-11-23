defmodule Hermit.Vpn.PairWorker do
  use GenServer, restart: :transient
  require Logger

  alias Hermit.Vpn.PairDiagnostics
  alias Hermit.Vpn.PairMetrics
  alias Hermit.Vpn.Pairs

  @topic "vpn_pairs"

  defstruct [
    :id,
    :inbound_profile_id,
    :outbound_profile_id,
    :wg_container_name,
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
    last_db_state: nil,
    smart_relayer_pid: nil
  ]

  # --- Client API ---

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(args.id))
  end

  @doc false
  def via_tuple(id), do: {:via, Registry, {Hermit.Vpn.Registry, id}}

  @doc false
  def safe_call(pid, msg, timeout \\ 15_000) do
    try do
      GenServer.call(pid, msg, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, reason}
    end
  end

  defdelegate list_pairs(), to: Pairs
  defdelegate update_wg_config(id, new_wg_config), to: Pairs
  defdelegate update_inbound_config(id, new_config), to: Pairs
  defdelegate update_outbound_config(id, new_config), to: Pairs

  def get_state(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, :get_state)
      {:error, reason} -> {:error, reason}
    end
  end

  def pause_pair(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, :pause)
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_pair(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, :resume)
      {:error, reason} -> {:error, reason}
    end
  end

  def restart_pair(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, :restart)
      {:error, reason} -> {:error, reason}
    end
  end

  def start_wg(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, {:start_wg})
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_wg(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil -> {:error, :not_found}
      pid -> safe_call(pid, {:stop_wg})
    end
  end

  def restart_wg(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, {:restart_wg})
      {:error, reason} -> {:error, reason}
    end
  end

  def start_ts(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, {:start_ts})
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_ts(id) do
    case GenServer.whereis(via_tuple(id)) do
      nil -> {:error, :not_found}
      pid -> safe_call(pid, {:stop_ts})
    end
  end

  def restart_ts(id) do
    case Pairs.ensure_worker_running(id) do
      {:ok, pid} -> safe_call(pid, {:restart_ts})
      {:error, reason} -> {:error, reason}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    id = args.id
    storage_dir = Path.join(PairDiagnostics.get_storage_base_path(), id)
    wg_config_path = Path.join(storage_dir, "wg0.conf")

    {wg_status, ts_status, overall_status, started_at, inbound_type, inbound_config,
     outbound_type, outbound_config, inbound_profile_id, outbound_profile_id} =
      Pairs.load_initial_state(id, args)

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
      inbound_profile_id: inbound_profile_id,
      outbound_profile_id: outbound_profile_id,
      wg_container_name: "hermit_wg_#{id}",
      wg_config_path: wg_config_path,
      wg_config_content: wg_config_content,
      ts_auth_key: ts_auth_key,
      status: overall_status,
      wg_status: wg_status,
      ts_status: ts_status,
      wg_error_reason: nil,
      ts_error_reason: nil,
      metrics: PairMetrics.default_metrics(),
      storage_dir: storage_dir,
      started_at: started_at,
      ts_port: nil,
      ts_retry_count: 0,
      wg_retry_count: 0,
      inbound_module: Pairs.inbound_module_for(inbound_type),
      outbound_module: Pairs.outbound_module_for(outbound_type),
      inbound_config: inbound_config,
      outbound_config: outbound_config,
      inbound_type: inbound_type,
      last_db_state: last_db_state
    }

    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.subscribe(Hermit.PubSub, "smart_routes")
    end

    state = sync_smart_routes_and_relayer(state)

    cond do
      wg_status == :starting and ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap}}

      wg_status == :starting ->
        {:ok, state, {:continue, :bootstrap_wg}}

      ts_status == :starting ->
        {:ok, state, {:continue, :bootstrap_ts}}

      true ->
        state = if wg_status == :running, do: schedule_metrics_poll(state), else: state
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
    teardown_pair_resources(state)

    updated_state = broadcast_update(%{state | ts_port: nil})
    {:noreply, updated_state}
  end

  @impl true
  def handle_continue(:restart_cleanup, state) do
    Logger.info("Running restart cleanup for VPN pair: #{state.id}")
    teardown_pair_resources(state)

    # Allow OS kernel to clean up netns and interfaces
    Process.sleep(1000)

    updated_state =
      state
      |> reload_outbound_from_db()
      |> Map.put(:ts_port, nil)
      |> broadcast_update()

    {:noreply, updated_state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:restart_wg_cleanup, state) do
    Logger.info("Running restart WG cleanup for VPN pair: #{state.id}")
    teardown_pair_resources(state)

    # Allow OS kernel to clean up netns and interfaces
    Process.sleep(1000)

    updated_state =
      state
      |> reload_outbound_from_db()
      |> Map.put(:ts_port, nil)
      |> broadcast_update()

    {:noreply, updated_state, {:continue, :bootstrap_wg}}
  end

  @impl true
  def handle_continue(:bootstrap_wg, state) do
    Logger.info("Bootstrapping WireGuard for VPN Pair: #{state.id}")

    try do
      File.mkdir_p!(state.storage_dir)
      File.mkdir_p!(Path.join(state.storage_dir, "tailscale"))

      if is_binary(state.wg_config_content) and String.trim(state.wg_config_content) != "" do
        resolved_content = PairDiagnostics.resolve_endpoint_in_config(state.wg_config_content)
        File.write!(state.wg_config_path, resolved_content)
        File.chmod!(state.wg_config_path, 0o600)
      end

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

          {:noreply, broadcast_update(error_state)}

        :ok ->
          outbound_cfg =
            (state.outbound_config || %{})
            |> Map.put("retry_attempt", state.wg_retry_count)

          case state.outbound_module.bootstrap(
                 state.id,
                 state.storage_dir,
                 outbound_cfg
               ) do
            {:ok, iface} ->
              updated_state =
                %{
                  state
                  | wg_status: :starting,
                    wg_error_reason: nil,
                    outbound_if: iface
                }
                |> broadcast_update()
                |> schedule_metrics_poll()

              send(self(), {:check_wg_health, 10})
              {:noreply, updated_state}

            {:error, reason} ->
              error_state =
                %{
                  state
                  | wg_status: :error,
                    wg_error_reason: "WireGuard creation failed: #{inspect(reason)}"
                }
                |> broadcast_update()

              maybe_schedule_wg_recovery(error_state)
              {:noreply, error_state}
          end
      end
    rescue
      e ->
        Logger.error("Failed to write configurations or start WG: #{inspect(e)}")

        error_state =
          %{
            state
            | wg_status: :error,
              wg_error_reason: "Setup failure: #{Exception.message(e)}"
          }
          |> broadcast_update()

        maybe_schedule_wg_recovery(error_state)
        {:noreply, error_state}
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
          metrics: PairMetrics.default_metrics()
      }
      |> cancel_metrics_poll()
      |> broadcast_update()

    {:reply, {:ok, updated_state}, updated_state, {:continue, :pause_cleanup}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Resuming VPN pair (both components): #{state.id}")

    updated_state =
      %{
        state
        | wg_status: :starting,
          ts_status: :starting,
          wg_error_reason: nil,
          ts_error_reason: nil,
          wg_retry_count: 0,
          ts_retry_count: 0
      }
      |> broadcast_update()

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
          metrics: PairMetrics.default_metrics(),
          wg_retry_count: 0,
          ts_retry_count: 0
      }
      |> cancel_metrics_poll()
      |> broadcast_update()

    {:reply, {:ok, updated_state}, updated_state, {:continue, :restart_cleanup}}
  end

  @impl true
  def handle_call({:start_wg}, _from, state) do
    updated_state = broadcast_update(%{state | wg_status: :starting, wg_error_reason: nil})
    {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_wg}}
  end

  @impl true
  def handle_call({:stop_wg}, _from, state) do
    Logger.info("Stopping WireGuard for pair: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)
    teardown_pair_resources(state)

    updated_state =
      %{
        state
        | wg_status: :stopped,
          ts_status: :stopped,
          wg_error_reason: nil,
          ts_error_reason: nil,
          ts_port: nil,
          started_at: nil,
          metrics: PairMetrics.default_metrics()
      }
      |> cancel_metrics_poll()
      |> broadcast_update()

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
          metrics: PairMetrics.default_metrics()
      }
      |> cancel_metrics_poll()
      |> broadcast_update()

    {:reply, {:ok, updated_state}, updated_state, {:continue, :restart_wg_cleanup}}
  end

  @impl true
  def handle_call({:update_wg_config, new_wg_config}, _from, state) do
    Logger.info("Updating WireGuard config for pair: #{state.id}")
    apply_outbound_config_update(%{state | wg_config_content: new_wg_config}, new_wg_config)
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

    apply_outbound_config_update(updated_state, new_wg_config)
  end

  @impl true
  def handle_call({:set_inbound_config, new_config}, _from, state) do
    updated_state = broadcast_update(%{state | inbound_config: new_config})
    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:update_inbound_config, new_config}, _from, state) do
    old_auth_key =
      Map.get(state.inbound_config || %{}, "ts_auth_key") ||
        Map.get(state.inbound_config || %{}, :ts_auth_key)

    new_auth_key =
      Map.get(new_config, "ts_auth_key") ||
        Map.get(new_config, :ts_auth_key)

    auth_key_changed? = new_auth_key != nil and new_auth_key != old_auth_key

    old_targets =
      Map.get(state.inbound_config || %{}, "routing_targets") ||
        Map.get(state.inbound_config || %{}, :routing_targets)

    new_targets =
      Map.get(new_config, "routing_targets") ||
        Map.get(new_config, :routing_targets)

    if new_targets != nil and new_targets != old_targets do
      Hermit.Vpn.SniProxy.sync_all_routes()
    end

    updated_state =
      %{state | inbound_config: new_config}
      |> sync_smart_routes_and_relayer()
      |> broadcast_update()

    cond do
      auth_key_changed? and state.wg_status == :running ->
        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}

      state.inbound_type == "proxy" and state.wg_status == :running ->
        _ = maybe_shutdown_bootstrap_task(state)
        if state.ts_port, do: stop_inbound_process(state.ts_port)
        state.inbound_module.cleanup(state.id, state.storage_dir)

        updated_state =
          %{updated_state | ts_status: :starting, ts_error_reason: nil, ts_port: nil}
          |> broadcast_update()

        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}

      state.ts_status == :running ->
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

      state.ts_status == :error and state.wg_status == :running ->
        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}

      true ->
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

      not PairDiagnostics.netns_exists?(state.wg_container_name) ->
        {:reply, {:error, "Network namespace does not exist. WireGuard must be started first."},
         state}

      true ->
        updated_state = broadcast_update(%{state | ts_status: :starting, ts_error_reason: nil})
        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
    end
  end

  @impl true
  def handle_call({:stop_ts}, _from, state) do
    Logger.info("Stopping Tailscale for pair: #{state.id}")

    state = maybe_shutdown_bootstrap_task(state)
    if state.ts_port, do: stop_inbound_process(state.ts_port)
    Hermit.Vpn.SniProxy.unregister_pair(state.id)

    if state.smart_relayer_pid && Process.alive?(state.smart_relayer_pid) do
      Process.exit(state.smart_relayer_pid, :shutdown)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)

    updated_state =
      %{state | ts_status: :stopped, ts_error_reason: nil, ts_port: nil, started_at: nil}
      |> broadcast_update()

    {:reply, {:ok, updated_state}, updated_state}
  end

  @impl true
  def handle_call({:restart_ts}, _from, state) do
    cond do
      state.wg_status != :running ->
        {:reply,
         {:error, "WireGuard is not running. Outbound connection must be established first."},
         state}

      not PairDiagnostics.netns_exists?(state.wg_container_name) ->
        {:reply, {:error, "Network namespace does not exist. WireGuard must be started first."},
         state}

      true ->
        Logger.info("Restarting Tailscale for pair: #{state.id}")

        state = maybe_shutdown_bootstrap_task(state)
        if state.ts_port, do: stop_inbound_process(state.ts_port)
        state.inbound_module.cleanup(state.id, state.storage_dir)

        updated_state =
          %{state | ts_status: :starting, ts_error_reason: nil, ts_port: nil}
          |> broadcast_update()

        {:reply, {:ok, updated_state}, updated_state, {:continue, :bootstrap_ts}}
    end
  end

  @impl true
  def handle_info({:smart_routes_updated, _all_pairs}, state) do
    {:noreply, sync_smart_routes_and_relayer(state)}
  end

  @impl true
  def handle_info({:inbound_config_updated, _new_config}, state) do
    if state.ts_error_reason || state.ts_status == :error do
      {:noreply, broadcast_update(%{state | ts_error_reason: nil, ts_status: :running})}
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

    {:noreply, broadcast_update(error_state)}
  end

  @impl true
  def handle_info({:check_wg_health, retries}, state) do
    case state.outbound_module.get_status(state.id, state.storage_dir) do
      :running ->
        PairDiagnostics.trigger_handshake("hermit_wg_#{state.id}")

        case state.outbound_module.get_metrics(state.id, state.storage_dir) do
          {:ok, %{bytes_received: bytes_received}}
          when bytes_received > 0 or state.outbound_module == Hermit.Vpn.Outbound.Local ->
            state =
              if state.wg_status != :running do
                %{state | wg_status: :running, wg_error_reason: nil, wg_retry_count: 0}
                |> sync_smart_routes_and_relayer()
                |> broadcast_update()
              else
                state
              end

            if state.ts_status == :starting and is_nil(state.bootstrap_task) do
              {:noreply, start_inbound_bootstrap_task(state)}
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
        updated_state = broadcast_update(%{state | metrics: metrics, current_ping_task: nil})
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
      updated_state = broadcast_update(%{state | metrics: metrics, current_ping_task: nil})
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
            if PairMetrics.should_poll_inbound?(state) do
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

          metrics =
            outbound_metrics
            |> Map.merge(inbound_info)
            |> Map.put(:latency, Map.get(state.metrics || %{}, :latency))

          now = System.system_time(:second)

          state =
            if PairMetrics.has_active_ui?() and is_nil(state.current_ping_task) and
                 now - state.latency_last_checked_at >= 30 do
              task =
                Task.async(fn ->
                  PairDiagnostics.measure_ping(state.outbound_module, state.id)
                end)

              %{state | current_ping_task: task, latency_last_checked_at: now}
            else
              state
            end

          new_ts_ips = Map.get(metrics, :ts_ips, [])
          old_ts_ips = get_in(state.metrics || %{}, [:ts_ips]) || []

          if new_ts_ips != old_ts_ips do
            Hermit.Vpn.SniProxy.IpResolver.clear_cache()
          end

          updated_state =
            %{state | metrics: metrics, wg_retry_count: 0}
            |> broadcast_update()
            |> schedule_metrics_poll()

          {:noreply, updated_state}

        _error ->
          case state.outbound_module.get_status(state.id, state.storage_dir) do
            :running ->
              {:noreply, schedule_metrics_poll(state)}

            _ ->
              if state.status != :stopped do
                Logger.error(
                  "WireGuard namespace is down for pair #{state.id}. Triggering recovery..."
                )

                if state.ts_port, do: stop_inbound_process(state.ts_port)
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
                  |> broadcast_update()

                maybe_schedule_wg_recovery(error_state)
                {:noreply, error_state}
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

      error_state =
        %{
          state
          | ts_status: :error,
            ts_error_reason: "Tailscale daemon exited unexpectedly: #{inspect(reason)}",
            ts_port: nil,
            started_at: nil
        }
        |> broadcast_update()

      maybe_schedule_ts_recovery(error_state)
      {:noreply, error_state}
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
          |> broadcast_update()

        {:noreply, updated_state, {:continue, :bootstrap}}
      else
        Logger.error("Max WireGuard recovery retries reached for pair: #{state.id}")

        last_reason = state.wg_error_reason || "WireGuard connection failed"

        final_reason =
          if String.contains?(last_reason, "Max retries reached") do
            last_reason
          else
            "#{last_reason} (Max retries reached)"
          end

        {:noreply, broadcast_update(%{state | wg_status: :error, wg_error_reason: final_reason})}
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
        if state.ts_port, do: stop_inbound_process(state.ts_port)
        state.inbound_module.cleanup(state.id, state.storage_dir)

        updated_state =
          %{
            state
            | ts_status: :starting,
              ts_error_reason: nil,
              ts_port: nil,
              ts_retry_count: state.ts_retry_count + 1
          }
          |> broadcast_update()

        {:noreply, updated_state, {:continue, :bootstrap_ts}}
      else
        Logger.error("Max Tailscale recovery retries reached for pair: #{state.id}")

        last_reason = state.ts_error_reason || "Tailscale connection failed"

        final_reason =
          if String.contains?(last_reason, "Max retries reached") do
            last_reason
          else
            "#{last_reason} (Max retries reached)"
          end

        {:noreply, broadcast_update(%{state | ts_status: :error, ts_error_reason: final_reason})}
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

        error_state =
          %{
            state
            | ts_status: :error,
              ts_error_reason: "Inbound proxy exited unexpectedly: #{inspect(reason)}",
              ts_port: nil,
              started_at: nil
          }
          |> broadcast_update()

        maybe_schedule_ts_recovery(error_state)
        {:noreply, error_state}

      pid == state.smart_relayer_pid ->
        if reason not in [:normal, :shutdown, :killed] do
          Logger.warning("Smart relayer for pair #{state.id} exited: #{inspect(reason)}")
        end

        {:noreply, %{state | smart_relayer_pid: nil}}

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

    _ = maybe_shutdown_bootstrap_task(state)
    teardown_pair_resources(state)
    :ok
  end

  # --- Internal Helpers ---

  defp teardown_pair_resources(state) do
    if state.ts_port, do: stop_inbound_process(state.ts_port)
    Hermit.Vpn.SniProxy.unregister_pair(state.id)

    if state.smart_relayer_pid && Process.alive?(state.smart_relayer_pid) do
      Process.exit(state.smart_relayer_pid, :shutdown)
    end

    state.inbound_module.cleanup(state.id, state.storage_dir)
    state.outbound_module.cleanup(state.id, state.storage_dir)
    :ok
  end

  defp apply_outbound_config_update(updated_state, new_wg_config) do
    updated_state = maybe_shutdown_bootstrap_task(updated_state)

    try do
      File.mkdir_p!(updated_state.storage_dir)

      if is_binary(new_wg_config) and String.trim(new_wg_config) != "" do
        resolved_content = PairDiagnostics.resolve_endpoint_in_config(new_wg_config)
        File.write!(updated_state.wg_config_path, resolved_content)
        File.chmod!(updated_state.wg_config_path, 0o600)
      end

      updated_state = broadcast_update(updated_state)

      if updated_state.wg_status in [:running, :starting, :error] do
        if updated_state.ts_port, do: stop_inbound_process(updated_state.ts_port)
        updated_state.inbound_module.cleanup(updated_state.id, updated_state.storage_dir)
        updated_state.outbound_module.cleanup(updated_state.id, updated_state.storage_dir)

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
          |> broadcast_update()

        {:reply, {:ok, restarted_state}, restarted_state, {:continue, :bootstrap_wg}}
      else
        {:reply, {:ok, updated_state}, updated_state}
      end
    rescue
      e ->
        Logger.error("Failed to update Outbound/WG config file: #{inspect(e)}")

        error_state =
          %{
            updated_state
            | wg_status: :error,
              wg_error_reason: "Config update setup failure: #{Exception.message(e)}"
          }
          |> broadcast_update()

        {:reply, {:error, Exception.message(e)}, error_state}
    end
  end

  defp start_inbound_bootstrap_task(state) do
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
    %{state | bootstrap_task: %{pid: task_pid, ref: ref}}
  end

  defp retry_health_check(0, state) do
    diagnostic_reason =
      try do
        PairDiagnostics.diagnose_wg_handshake_failure(state)
      rescue
        e ->
          Logger.warning("Error during WireGuard handshake failure diagnosis: #{inspect(e)}")
          "WireGuard Handshake Timeout: Tunnel failed to establish connection within 10 seconds."
      end

    Logger.error("WireGuard tunnel handshake timeout for pair #{state.id}: #{diagnostic_reason}")

    error_state =
      %{
        state
        | wg_status: :error,
          wg_error_reason: diagnostic_reason,
          ts_status: if(state.ts_status == :starting, do: :stopped, else: state.ts_status),
          ts_error_reason: nil
      }
      |> broadcast_update()
      |> schedule_metrics_poll()

    if state.outbound_module == Hermit.Vpn.Outbound.Warp do
      maybe_schedule_wg_recovery(error_state)
    end

    {:noreply, error_state}
  end

  defp retry_health_check(retries, state) do
    Process.send_after(self(), {:check_wg_health, retries - 1}, 1000)
    {:noreply, state}
  end

  defp schedule_metrics_poll(state) do
    if state.metrics_timer, do: Process.cancel_timer(state.metrics_timer)
    timer = Process.send_after(self(), :poll_metrics, PairMetrics.poll_interval_ms())
    %{state | metrics_timer: timer}
  end

  defp cancel_metrics_poll(state) do
    if state.metrics_timer, do: Process.cancel_timer(state.metrics_timer)
    cancel_ping_task(%{state | metrics_timer: nil})
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
    {overall_status, error_reason} = PairMetrics.compute_overall_status(state)
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
        Pairs.update_db_status(
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

    if db_changed? do
      Hermit.Vpn.SniProxy.IpResolver.clear_cache()
    end

    Phoenix.PubSub.broadcast(Hermit.PubSub, @topic, {:vpn_pair_updated, state_with_db})

    state_with_db
  end

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

        running_state =
          %{
            state
            | ts_status: :running,
              ts_error_reason: nil,
              started_at: System.system_time(:second),
              ts_port: port,
              ts_retry_count: 0
          }
          |> broadcast_update()
          |> schedule_metrics_poll()

        {:noreply, running_state}

      {:error, reason} ->
        error_state =
          %{
            state
            | ts_status: :error,
              ts_error_reason: PairDiagnostics.format_inbound_error(reason, state.inbound_type)
          }
          |> broadcast_update()

        maybe_schedule_ts_recovery(error_state)
        {:noreply, schedule_metrics_poll(error_state)}
    end
  end

  defp sync_smart_routes_and_relayer(state) do
    if Hermit.Vpn.SniProxy.has_routes?(state.id) do
      if state.inbound_type != "proxy" and state.wg_status == :running do
        if state.smart_relayer_pid == nil or not Process.alive?(state.smart_relayer_pid) do
          case Hermit.Vpn.Inbound.Proxy.Relayer.start_link(
                 pair_id: state.id,
                 storage_dir: state.storage_dir,
                 port: 0
               ) do
            {:ok, pid} ->
              %{state | smart_relayer_pid: pid}

            {:error, reason} ->
              Logger.warning(
                "Failed to start smart DNS Proxy.Relayer sidecar for #{state.id}: #{inspect(reason)}"
              )

              state
          end
        else
          state
        end
      else
        state
      end
    else
      if state.smart_relayer_pid && Process.alive?(state.smart_relayer_pid) do
        Process.exit(state.smart_relayer_pid, :shutdown)
        %{state | smart_relayer_pid: nil}
      else
        state
      end
    end
  rescue
    e ->
      Logger.warning("Error in sync_smart_routes_and_relayer for #{state.id}: #{inspect(e)}")
      state
  end

  defp reload_outbound_from_db(state) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, state.id) do
      nil ->
        state

      pair ->
        pair = Hermit.Repo.preload(pair, [:outbound_profile])

        {outbound_type, outbound_config} =
          cond do
            pair.outbound_config && map_size(pair.outbound_config) > 0 ->
              profile_cfg = (pair.outbound_profile && pair.outbound_profile.config) || %{}
              merged = Map.merge(profile_cfg, pair.outbound_config)

              {pair.outbound_type || (pair.outbound_profile && pair.outbound_profile.type) ||
                 "wireguard", merged}

            pair.outbound_profile ->
              {pair.outbound_profile.type, pair.outbound_profile.config || %{}}

            true ->
              {"wireguard", %{}}
          end

        wg_config_content =
          if outbound_type == "wireguard" do
            Map.get(outbound_config, "wg_config") ||
              Map.get(outbound_config, :wg_config) ||
              state.wg_config_content
          else
            nil
          end

        %{
          state
          | outbound_profile_id: pair.outbound_profile_id || state.outbound_profile_id,
            outbound_module: Pairs.outbound_module_for(outbound_type),
            outbound_config: outbound_config,
            wg_config_content: wg_config_content
        }
    end
  rescue
    _ -> state
  end
end
