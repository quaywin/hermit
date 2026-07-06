defmodule Hermit.Vpn.DnsLogReceiver do
  use GenServer
  require Logger

  @table :dns_query_logs

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_recent_logs(pair_id, limit \\ 100) do
    pattern = {{pair_id, :"$1"}, :"$2"}

    records = :ets.select(@table, [{pattern, [], [:"$$"]}])

    records
    |> Enum.sort_by(fn [counter, _log] -> counter end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn [_counter, log] -> log end)
  end

  def clear_logs(pair_id) do
    GenServer.cast(__MODULE__, {:clear_logs, pair_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    port = opts[:port] || 5300

    :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])

    # Schedule periodic log pruning every 10 seconds to save CPU
    :erlang.send_after(10_000, self(), :periodic_prune)

    case :gen_udp.open(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("DNS Log Receiver listening on UDP port #{port}")
        {:ok, %{socket: socket, port: port}}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket on port #{port}: #{inspect(reason)}")
        {:ok, %{socket: nil, port: port}}
    end
  end

  @impl true
  def handle_info({:udp, _socket, ip, _port, packet}, state) do
    case Jason.decode(packet) do
      {:ok, %{"pair_id" => pair_id} = log} ->
        client_ip = log["client_ip"] || ip_to_string(ip)
        profile_id = get_profile_id(pair_id)

        client_name =
          if profile_id do
            Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip)
          else
            client_ip
          end

        log =
          log
          |> Map.put("client_ip", client_ip)
          |> Map.put("client_name", client_name || client_ip)

        counter = System.unique_integer([:monotonic])
        :ets.insert(@table, {{pair_id, counter}, log})

        Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{pair_id}", {:dns_log, log})

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:periodic_prune, state) do
    # Find all unique pair_ids in the table
    # Standard query to select all keys: {{pair_id, counter}, _}
    # We retrieve the pair_ids to prune them individually
    pair_ids =
      :ets.select(@table, [{{{:"$1", :_}, :_}, [], [:"$1"]}])
      |> Enum.uniq()

    Enum.each(pair_ids, fn pair_id ->
      prune_logs(pair_id)
    end)

    :erlang.send_after(10_000, self(), :periodic_prune)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_logs, pair_id}, state) do
    pattern = {{pair_id, :"$1"}, :_}
    :ets.select_delete(@table, [{pattern, [], [true]}])
    {:noreply, state}
  end

  # --- Helpers ---

  defp get_profile_id(pair_id) do
    case Integer.parse(pair_id) do
      {profile_id, ""} ->
        profile_id

      _ ->
        try do
          case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id) do
            nil -> nil
            pair -> pair.inbound_profile_id
          end
        rescue
          _ -> nil
        end
    end
  end

  defp ip_to_string(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      charlist when is_list(charlist) -> List.to_string(charlist)
      _ -> "unknown"
    end
  end

  defp ip_to_string(other), do: to_string(other)

  defp prune_logs(pair_id) do
    pattern = {{pair_id, :"$1"}, :_}
    keys = :ets.select(@table, [{pattern, [], [:"$1"]}])

    if length(keys) > 100 do
      sorted_keys = Enum.sort(keys)
      to_delete_count = length(sorted_keys) - 100

      Enum.take(sorted_keys, to_delete_count)
      |> Enum.each(fn counter ->
        :ets.delete(@table, {pair_id, counter})
      end)
    end
  end
end
