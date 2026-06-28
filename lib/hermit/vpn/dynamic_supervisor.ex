defmodule Hermit.Vpn.DynamicSupervisor do
  use DynamicSupervisor
  require Logger

  # --- Client API ---

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Dynamically starts a new VPN Pair worker.
  """
  def start_pair(args) do
    # args: %{id: id, wg_config: wg_config, ts_auth_key: ts_auth_key}
    Logger.info("DynamicSupervisor: starting VPN pair child for ID: #{args.id}")

    vpn_pair = %Hermit.Vpn.VpnPair{
      pair_id: args.id,
      wg_config: args.wg_config,
      ts_auth_key: args.ts_auth_key,
      status: "running",
      wg_status: "starting",
      ts_status: "starting"
    }

    case Hermit.Repo.insert(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id) do
      {:ok, _} ->
        case DynamicSupervisor.start_child(__MODULE__, {Hermit.Vpn.PairWorker, args}) do
          {:ok, pid} -> {:ok, pid}
          {:ok, pid, _info} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to persist VPN pair to SQLite: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops and deletes a VPN pair worker, which triggers container cleanup in terminate/2.
  """
  def stop_pair(id) do
    Logger.info("DynamicSupervisor: stopping VPN pair child for ID: #{id}")

    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil -> :ok
      pair -> Hermit.Repo.delete(pair)
    end

    case Registry.lookup(Hermit.Vpn.Registry, id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  # --- Callbacks ---

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
