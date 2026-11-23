defmodule Hermit.Vpn.Pairs do
  @moduledoc """
  Persistence, query, configuration update, and worker lookup context for VPN pairs.
  """
  require Logger
  alias Hermit.Vpn.PairDiagnostics
  alias Hermit.Vpn.PairMetrics
  alias Hermit.Vpn.PairWorker

  def inbound_module_for("tailscale"), do: Hermit.Vpn.Inbound.Tailscale
  def inbound_module_for("proxy"), do: Hermit.Vpn.Inbound.Proxy
  def inbound_module_for(_), do: Hermit.Vpn.Inbound.Tailscale

  def outbound_module_for("wireguard"), do: Hermit.Vpn.Outbound.WireGuard
  def outbound_module_for("warp"), do: Hermit.Vpn.Outbound.Warp
  def outbound_module_for("local"), do: Hermit.Vpn.Outbound.Local
  def outbound_module_for(_), do: Hermit.Vpn.Outbound.WireGuard

  def ensure_worker_running(id) do
    case GenServer.whereis(PairWorker.via_tuple(id)) do
      nil ->
        case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
          nil ->
            {:error, :not_found}

          pair ->
            case DynamicSupervisor.start_child(
                   Hermit.Vpn.DynamicSupervisor,
                   {PairWorker,
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
            {:ok, updated_pair} ->
              case GenServer.whereis(PairWorker.via_tuple(id)) do
                nil ->
                  case ensure_worker_running(id) do
                    {:ok, pid} -> PairWorker.safe_call(pid, {:update_wg_config, new_wg_config})
                    _ -> {:ok, updated_pair}
                  end

                pid ->
                  PairWorker.safe_call(pid, {:update_wg_config, new_wg_config})
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
            case GenServer.whereis(PairWorker.via_tuple(id)) do
              nil ->
                case ensure_worker_running(id) do
                  {:ok, pid} ->
                    PairWorker.safe_call(
                      pid,
                      {:update_inbound_config, updated_pair.inbound_config}
                    )

                  _ ->
                    {:ok, updated_pair}
                end

              pid ->
                PairWorker.safe_call(pid, {:update_inbound_config, updated_pair.inbound_config})
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
            case GenServer.whereis(PairWorker.via_tuple(id)) do
              nil ->
                case ensure_worker_running(id) do
                  {:ok, pid} ->
                    PairWorker.safe_call(
                      pid,
                      {:update_outbound_config, updated_pair.outbound_config}
                    )

                  _ ->
                    {:ok, updated_pair}
                end

              pid ->
                PairWorker.safe_call(pid, {:update_outbound_config, updated_pair.outbound_config})
            end

          {:error, changeset} ->
            {:error, changeset}
        end
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
      case GenServer.whereis(PairWorker.via_tuple(id)) do
        nil ->
          pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)
          build_offline_state(pair, id)

        pid ->
          try do
            GenServer.call(pid, :get_state, 1000)
          catch
            _, _ ->
              pair = Enum.find(persisted_pairs, fn p -> p.pair_id == id end)
              build_offline_state(pair, id)
          end
      end
    end)
  end

  def build_offline_state(pair, id) do
    {inbound_type, inbound_config} =
      cond do
        pair && pair.inbound_config && map_size(pair.inbound_config) > 0 ->
          profile_cfg = (pair.inbound_profile && pair.inbound_profile.config) || %{}
          merged = Map.merge(pair.inbound_config, profile_cfg)

          {pair.inbound_type || (pair.inbound_profile && pair.inbound_profile.type) ||
             "tailscale", merged}

        pair && pair.inbound_profile ->
          {pair.inbound_profile.type, pair.inbound_profile.config || %{}}

        true ->
          {"tailscale", %{}}
      end

    {outbound_type, outbound_config} =
      cond do
        pair && pair.outbound_config && map_size(pair.outbound_config) > 0 ->
          profile_cfg = (pair.outbound_profile && pair.outbound_profile.config) || %{}
          merged = Map.merge(pair.outbound_config, profile_cfg)

          {pair.outbound_type || (pair.outbound_profile && pair.outbound_profile.type) ||
             "wireguard", merged}

        pair && pair.outbound_profile ->
          {pair.outbound_profile.type, pair.outbound_profile.config || %{}}

        true ->
          {"wireguard", %{}}
      end

    base_path = PairDiagnostics.get_storage_base_path()

    struct(PairWorker,
      id: id,
      inbound_profile_id: pair && pair.inbound_profile_id,
      outbound_profile_id: pair && pair.outbound_profile_id,
      wg_container_name: "hermit_wg_#{id}",
      wg_config_path: Path.join([base_path, id, "wg0.conf"]),
      wg_config_content:
        Map.get(outbound_config, "wg_config") || Map.get(outbound_config, :wg_config) || "",
      ts_auth_key:
        Map.get(inbound_config, "ts_auth_key") || Map.get(inbound_config, :ts_auth_key) || "",
      status: String.to_atom((pair && pair.status) || "stopped"),
      error_reason: pair && (pair.wg_error_reason || pair.ts_error_reason),
      wg_status: String.to_atom((pair && pair.wg_status) || "stopped"),
      ts_status: String.to_atom((pair && pair.ts_status) || "stopped"),
      wg_error_reason: pair && pair.wg_error_reason,
      ts_error_reason: pair && pair.ts_error_reason,
      metrics: PairMetrics.default_metrics(),
      storage_dir: Path.join(base_path, id),
      started_at: pair && pair.started_at,
      ts_port: nil,
      inbound_module: inbound_module_for(inbound_type),
      outbound_module: outbound_module_for(outbound_type),
      inbound_config: inbound_config,
      outbound_config: outbound_config,
      inbound_type: inbound_type
    )
  end

  def load_initial_state(id, args) do
    try do
      case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
        nil ->
          default_initial_state(args)

        pair ->
          pair = Hermit.Repo.preload(pair, [:inbound_profile, :outbound_profile])

          {inbound_type, inbound_config} =
            cond do
              pair.inbound_config && map_size(pair.inbound_config) > 0 ->
                profile_cfg = (pair.inbound_profile && pair.inbound_profile.config) || %{}
                merged = Map.merge(pair.inbound_config, profile_cfg)

                {pair.inbound_type || (pair.inbound_profile && pair.inbound_profile.type) ||
                   "tailscale", merged}

              pair.inbound_profile ->
                cfg = pair.inbound_profile.config || %{}
                save_inbound_config_db(pair, cfg)
                {pair.inbound_profile.type, cfg}

              true ->
                {"tailscale", %{}}
            end

          {outbound_type, outbound_config} =
            cond do
              pair.outbound_config && map_size(pair.outbound_config) > 0 ->
                profile_cfg = (pair.outbound_profile && pair.outbound_profile.config) || %{}
                merged = Map.merge(pair.outbound_config, profile_cfg)

                {pair.outbound_type || (pair.outbound_profile && pair.outbound_profile.type) ||
                   "wireguard", merged}

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
            outbound_config,
            pair.inbound_profile_id || args[:inbound_profile_id],
            pair.outbound_profile_id || args[:outbound_profile_id]
          }
      end
    rescue
      e ->
        Logger.error("Failed to load VPN pair state from database during init: #{inspect(e)}")
        default_initial_state(args)
    end
  end

  defp default_initial_state(args) do
    {:starting, :starting, :starting_wg, nil, args[:inbound_type] || "tailscale",
     args[:inbound_config] || %{"ts_auth_key" => args[:ts_auth_key]},
     args[:outbound_type] || "wireguard",
     args[:outbound_config] ||
       %{"wg_config" => args[:wg_config] || args[:wg_config_content]}, args[:inbound_profile_id],
     args[:outbound_profile_id]}
  end

  def update_db_status(id, wg_status, ts_status, wg_err, ts_err, overall_status, started_at) do
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

  def save_inbound_config_db(pair, config) do
    pair
    |> Hermit.Vpn.VpnPair.changeset(%{inbound_config: config})
    |> Hermit.Repo.update()
  rescue
    _ -> :ok
  end

  def save_outbound_config_db(pair, config) do
    pair
    |> Hermit.Vpn.VpnPair.changeset(%{outbound_config: config})
    |> Hermit.Repo.update()
  rescue
    _ -> :ok
  end
end
