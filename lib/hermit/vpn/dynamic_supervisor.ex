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
    pair_id = args[:id] || args["id"] || args[:pair_id] || args["pair_id"]
    inbound_profile_id = to_int(args[:inbound_profile_id] || args["inbound_profile_id"])
    outbound_profile_id = to_int(args[:outbound_profile_id] || args["outbound_profile_id"])

    Logger.info("DynamicSupervisor: starting VPN pair child for ID: #{pair_id}")

    inbound_profile = Hermit.Repo.get(Hermit.Vpn.InboundProfile, inbound_profile_id)
    outbound_profile = Hermit.Repo.get(Hermit.Vpn.OutboundProfile, outbound_profile_id)

    inbound_config = (inbound_profile && inbound_profile.config) || %{}
    inbound_type = (inbound_profile && inbound_profile.type) || "tailscale"

    outbound_config = (outbound_profile && outbound_profile.config) || %{}
    outbound_type = (outbound_profile && outbound_profile.type) || "wireguard"

    existing_pair = Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id)

    vpn_pair =
      if existing_pair do
        inbound_changed? =
          existing_pair.inbound_profile_id != inbound_profile_id or
            existing_pair.inbound_type != inbound_type

        outbound_changed? =
          existing_pair.outbound_profile_id != outbound_profile_id or
            existing_pair.outbound_type != outbound_type

        pair_inbound_config =
          if inbound_changed? do
            inbound_config
          else
            if existing_pair.inbound_config && map_size(existing_pair.inbound_config) > 0 do
              existing_pair.inbound_config
            else
              inbound_config
            end
          end

        pair_outbound_config =
          if outbound_changed? do
            outbound_config
          else
            if existing_pair.outbound_config && map_size(existing_pair.outbound_config) > 0 do
              existing_pair.outbound_config
            else
              outbound_config
            end
          end

        %{
          existing_pair
          | inbound_profile_id: inbound_profile_id,
            outbound_profile_id: outbound_profile_id,
            inbound_type:
              if(inbound_changed?,
                do: inbound_type,
                else: existing_pair.inbound_type || inbound_type
              ),
            inbound_config: pair_inbound_config,
            outbound_type:
              if(outbound_changed?,
                do: outbound_type,
                else: existing_pair.outbound_type || outbound_type
              ),
            outbound_config: pair_outbound_config,
            status: "running",
            wg_status: "starting",
            ts_status: "starting"
        }
      else
        %Hermit.Vpn.VpnPair{
          pair_id: pair_id,
          inbound_profile_id: inbound_profile_id,
          outbound_profile_id: outbound_profile_id,
          inbound_type: inbound_type,
          inbound_config: inbound_config,
          outbound_type: outbound_type,
          outbound_config: outbound_config,
          status: "running",
          wg_status: "starting",
          ts_status: "starting"
        }
      end

    worker_args = %{
      id: pair_id,
      inbound_profile_id: inbound_profile_id,
      outbound_profile_id: outbound_profile_id
    }

    case Hermit.Repo.insert(vpn_pair, on_conflict: :replace_all, conflict_target: :pair_id) do
      {:ok, _} ->
        case DynamicSupervisor.start_child(__MODULE__, {Hermit.Vpn.PairWorker, worker_args}) do
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

    result =
      case Registry.lookup(Hermit.Vpn.Registry, id) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(__MODULE__, pid)

        [] ->
          {:error, :not_found}
      end

    case Hermit.Repo.get(Hermit.Vpn.VpnPair, id) do
      nil -> :ok
      pair -> Hermit.Repo.delete(pair)
    end

    result
  end

  # --- Callbacks ---

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 1
    )
  end

  # --- Helpers ---

  defp to_int(nil), do: nil
  defp to_int(val) when is_integer(val), do: val

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      _ -> nil
    end
  end
end
