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
  def handle_info({:udp, _socket, _ip, _port, packet}, state) do
    case Jason.decode(packet) do
      {:ok, %{"pair_id" => pair_id} = log} ->
        counter = System.unique_integer([:monotonic])
        :ets.insert(@table, {{pair_id, counter}, log})

        Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{pair_id}", {:dns_log, log})

        prune_logs(pair_id)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
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
