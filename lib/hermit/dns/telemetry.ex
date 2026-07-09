defmodule Hermit.Dns.Telemetry do
  @moduledoc """
  Telemetry handler and manager for Hermit DNS events.
  Acts as a GenServer to manage the ETS table lifetime, attach handlers, and periodically prune old logs.
  Persists aggregated metrics into the SQLite database for durability.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Hermit.Repo
  alias Hermit.Dns.Packet
  alias Hermit.Dns.HourlyStat

  @dns_log_table :dns_query_logs
  @dns_metrics_table :dns_hourly_metrics
  @max_raw_logs 200

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # 1. Create the shared ETS raw log table if not already created
    if :ets.info(@dns_log_table) == :undefined do
      :ets.new(@dns_log_table, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])
    end

    # 2. Create the hourly metrics time-series table if not already created
    if :ets.info(@dns_metrics_table) == :undefined do
      :ets.new(@dns_metrics_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])
    end

    # 3. Restore hourly metrics from SQLite for the last 24 hours
    restore_metrics_from_db()

    # 4. Attach the telemetry handler
    :telemetry.attach(
      "hermit-dns-queries",
      [:hermit, :dns, :query],
      &__MODULE__.handle_event/4,
      nil
    )

    # 5. Schedule periodic sync and prune every 60 seconds
    :erlang.send_after(60_000, self(), :periodic_prune)
    # 6. Schedule periodic log flushing every 1 second
    :erlang.send_after(1000, self(), :flush_logs)
    # 7. Schedule daily DB cleanup (once on boot after 5s, then every 24h)
    :erlang.send_after(5000, self(), :daily_db_cleanup)

    {:ok, %{log_buffer: []}}
  end

  @impl true
  def handle_cast({:enqueue_log, log_data, config_id, block_reason}, state) do
    log_buffer = [{log_data, config_id, block_reason} | state.log_buffer]
    {:noreply, %{state | log_buffer: log_buffer}}
  end

  @impl true
  def handle_info(:flush_logs, state) do
    :erlang.send_after(1000, self(), :flush_logs)

    if state.log_buffer == [] do
      {:noreply, state}
    else
      logs_to_flush = Enum.reverse(state.log_buffer)

      # 1. Bulk insert to ETS
      ets_entries =
        Enum.flat_map(logs_to_flush, fn {log_data, config_id, _} ->
          pair_id = log_data["pair_id"]
          counter = System.unique_integer([:monotonic])
          [
            {{pair_id, counter}, log_data},
            {{config_id, counter}, log_data}
          ]
        end)

      :ets.insert(@dns_log_table, ets_entries)

      # 2. Hourly stats metrics
      Enum.each(logs_to_flush, fn {log_data, config_id, block_reason} ->
        hour_timestamp = div(log_data["timestamp"], 3600) * 3600
        config_id_str = to_string(config_id)
        status = log_data["status"]

        :ets.insert_new(@dns_metrics_table, {{config_id, hour_timestamp}, 0, 0, 0, 0, 0, 0, 0})
        :ets.insert_new(@dns_metrics_table, {{config_id_str, hour_timestamp}, 0, 0, 0, 0, 0, 0, 0})

        is_blocked = if status == "blocked", do: 1, else: 0
        is_ipv6_blocked = if block_reason == "ipv6", do: 1, else: 0
        is_adguard = if block_reason == "adguard", do: 1, else: 0
        is_goodbyeads = if block_reason == "goodbyeads", do: 1, else: 0
        is_adult = if block_reason == "adult", do: 1, else: 0
        is_custom = if block_reason == "custom_rule", do: 1, else: 0

        updates = [
          {2, 1},
          {3, is_blocked},
          {4, is_ipv6_blocked},
          {5, is_adguard},
          {6, is_goodbyeads},
          {7, is_adult},
          {8, is_custom}
        ]

        :ets.update_counter(@dns_metrics_table, {config_id, hour_timestamp}, updates)
        :ets.update_counter(@dns_metrics_table, {config_id_str, hour_timestamp}, updates)
      end)

      # 3. Broadcast
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        Enum.each(logs_to_flush, fn {log_data, config_id, _} ->
          pair_id = log_data["pair_id"]
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{pair_id}", {:dns_log, log_data})
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs_profile:#{config_id}", {:dns_log, log_data})
        end)
      end

      {:noreply, %{state | log_buffer: []}}
    end
  end

  @impl true
  def handle_info(:periodic_prune, state) do
    # A. Prune raw logs in RAM
    pair_ids = collect_pair_ids(@dns_log_table)
    Enum.each(pair_ids, fn pair_id ->
      prune_logs(pair_id)
    end)

    # B. Sync current in-memory metrics to SQLite
    sync_metrics_to_db()

    # C. Prune in-memory metrics older than 24 hours
    cutoff_ram_time = System.system_time(:second) - 24 * 3600
    :ets.select_delete(@dns_metrics_table, [
      {{{:"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_}, [{:<, :"$2", cutoff_ram_time}], [true]}
    ])

    :erlang.send_after(60_000, self(), :periodic_prune)
    {:noreply, state}
  end

  @impl true
  def handle_info(:daily_db_cleanup, state) do
    # Prune SQLite database metrics older than 30 days
    cutoff_db_time = System.system_time(:second) - 30 * 24 * 3600
    try do
      Repo.delete_all(from(s in HourlyStat, where: s.hour_timestamp < ^cutoff_db_time))
      Logger.info("Telemetry: Successfully pruned old SQLite metrics.")
    rescue
      e -> Logger.warning("Telemetry: Failed to prune old SQLite metrics: #{inspect(e)}")
    end

    # Schedule next run in 24 hours
    :erlang.send_after(24 * 3600 * 1000, self(), :daily_db_cleanup)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Telemetry Handler Callback ---

  @doc """
  Telemetry handler callback.
  Processes DNS query logs asynchronously to prevent blocking the DNS server.
  """
  def handle_event([:hermit, :dns, :query], measurements, metadata, _config) do
    if Map.get(metadata, :enable_query_logging, false) do
      duration = Map.get(measurements, :duration)
      profile_id = Map.get(metadata, :profile_id)
      config_id = Map.get(metadata, :config_id)
      client_ip_raw = Map.get(metadata, :client_ip)
      {client_ip, is_doh} =
        case client_ip_raw do
          {:doh, ip} -> {ip, true}
          ip -> {ip, false}
        end

      domain = Map.get(metadata, :domain)
      qtype = Map.get(metadata, :qtype)
      status = Map.get(metadata, :status)
      answer = Map.get(metadata, :answer)
      resolver = Map.get(metadata, :resolver)
      block_reason = Map.get(metadata, :block_reason)

      pair_id = to_string(profile_id)
      client_ip_str = ip_to_string(client_ip)

      client_name =
        if is_doh do
          nil
        else
          Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip_str)
        end

      log_data = %{
        "pair_id" => pair_id,
        "client_ip" => client_ip_str,
        "client_name" => client_name || client_ip_str,
        "domain" => domain,
        "type" => Packet.qtype_to_string(qtype),
        "status" => status,
        "answer" => answer,
        "resolver" => resolver,
        "duration_ms" => duration,
        "timestamp" => System.system_time(:second)
      }

      GenServer.cast(__MODULE__, {:enqueue_log, log_data, config_id, block_reason})
    end

    :ok
  end

  # --- Helper functions for database sync and restore ---

  defp restore_metrics_from_db do
    cutoff_time = System.system_time(:second) - 24 * 3600

    try do
      stats = Repo.all(from(s in HourlyStat, where: s.hour_timestamp >= ^cutoff_time))

      Enum.each(stats, fn stat ->
        config_id = stat.dns_config_id
        hour_timestamp = stat.hour_timestamp
        config_id_str = to_string(config_id)

        record = {
          {config_id, hour_timestamp},
          stat.total_queries,
          stat.blocked_queries,
          stat.ipv6_blocked_count,
          stat.adguard_blocked_count,
          stat.goodbyeads_blocked_count,
          stat.adult_blocked_count,
          stat.custom_blocked_count
        }

        record_str = {
          {config_id_str, hour_timestamp},
          stat.total_queries,
          stat.blocked_queries,
          stat.ipv6_blocked_count,
          stat.adguard_blocked_count,
          stat.goodbyeads_blocked_count,
          stat.adult_blocked_count,
          stat.custom_blocked_count
        }

        :ets.insert(@dns_metrics_table, record)
        :ets.insert(@dns_metrics_table, record_str)
      end)

      Logger.info("Telemetry: Successfully restored #{length(stats)} hourly metrics from database.")
    rescue
      e -> Logger.warning("Telemetry: Failed to restore metrics from SQLite: #{inspect(e)}")
    end
  end

  defp sync_metrics_to_db do
    try do
      records = :ets.tab2list(@dns_metrics_table)
      active_ids = Repo.all(from(d in Hermit.Vpn.DnsConfig, select: d.id))
      active_ids_set = MapSet.new(active_ids)

      Enum.each(records, fn
        {{config_id, hour_timestamp}, total, blocked, ipv6, adguard, goodbyeads, adult, custom} when is_integer(config_id) ->
          if MapSet.member?(active_ids_set, config_id) do
            stat_attrs = %{
              dns_config_id: config_id,
              hour_timestamp: hour_timestamp,
              total_queries: total,
              blocked_queries: blocked,
              ipv6_blocked_count: ipv6,
              adguard_blocked_count: adguard,
              goodbyeads_blocked_count: goodbyeads,
              adult_blocked_count: adult,
              custom_blocked_count: custom
            }

            changeset =
              %HourlyStat{}
              |> HourlyStat.changeset(stat_attrs)

            case Repo.insert(
                   changeset,
                   on_conflict: {:replace, [
                     :total_queries,
                     :blocked_queries,
                     :ipv6_blocked_count,
                     :adguard_blocked_count,
                     :goodbyeads_blocked_count,
                     :adult_blocked_count,
                     :custom_blocked_count,
                     :updated_at
                   ]},
                   conflict_target: [:dns_config_id, :hour_timestamp]
                 ) do
              {:ok, _} ->
                :ok

              {:error, changeset} ->
                Logger.warning("Telemetry: Failed to sync hourly metrics to SQLite: #{inspect(changeset.errors)}")
            end
          end
        _ ->
          :ok
      end)
    rescue
      e -> Logger.warning("Telemetry: Failed to sync hourly metrics to SQLite: #{inspect(e)}")
    end
  end

  # --- General helper functions ---

  defp ip_to_string(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      charlist when is_list(charlist) -> List.to_string(charlist)
      _ -> "unknown"
    end
  end

  defp ip_to_string(other), do: to_string(other)

  defp prune_logs(pair_id) do
    pattern = {{pair_id, :"$1"}, :_}
    keys = :ets.select(@dns_log_table, [{pattern, [], [:"$1"]}])
    count = length(keys)

    if count > @max_raw_logs do
      # keys already in ascending order from :ordered_set select
      Enum.take(keys, count - @max_raw_logs)
      |> Enum.each(fn counter ->
        :ets.delete(@dns_log_table, {pair_id, counter})
      end)
    end
  end

  defp collect_pair_ids(table) do
    case :ets.first(table) do
      :"$end_of_table" -> []
      first_key -> collect_pair_ids(table, first_key, MapSet.new())
    end
  end

  defp collect_pair_ids(table, {pair_id, _counter} = key, acc) do
    acc = MapSet.put(acc, pair_id)

    case :ets.next(table, key) do
      :"$end_of_table" -> MapSet.to_list(acc)
      next_key -> collect_pair_ids(table, next_key, acc)
    end
  end
end
