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

  def restore_metrics do
    GenServer.cast(__MODULE__, :restore_metrics)
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
  def handle_cast({:enqueue_log, log_data, config_id, block_reason, blocklist_id}, state) do
    log_buffer = [{log_data, config_id, block_reason, blocklist_id} | state.log_buffer]
    {:noreply, %{state | log_buffer: log_buffer}}
  end

  @impl true
  def handle_cast(:restore_metrics, state) do
    restore_metrics_from_db()
    {:noreply, state}
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
        Enum.flat_map(logs_to_flush, fn {log_data, config_id, _, _} ->
          pair_id = log_data["pair_id"]
          counter = System.unique_integer([:monotonic])

          [
            {{pair_id, counter}, log_data},
            {{config_id, counter}, log_data}
          ]
        end)

      :ets.insert(@dns_log_table, ets_entries)

      # 2. Hourly stats metrics
      Enum.each(logs_to_flush, fn {log_data, config_id, block_reason, blocklist_id} ->
        hour_timestamp = div(log_data["timestamp"], 3600) * 3600
        status = log_data["status"]

        :ets.insert_new(@dns_metrics_table, {{config_id, hour_timestamp}, 0, 0, 0, 0, 0, 0, 0})

        is_blocked = if status == "blocked", do: 1, else: 0
        is_ipv6_blocked = if block_reason == "ipv6", do: 1, else: 0

        is_adguard =
          if block_reason == "adguard" or
               (is_binary(block_reason) and
                  (String.contains?(String.downcase(block_reason), "adguard") or
                     not String.contains?(String.downcase(block_reason), [
                       "goodbye",
                       "adult",
                       "custom_rule"
                     ]))),
             do: 1,
             else: 0

        is_goodbyeads =
          if block_reason == "goodbyeads" or
               (is_binary(block_reason) and
                  String.contains?(String.downcase(block_reason), "goodbye")),
             do: 1,
             else: 0

        is_adult =
          if block_reason == "adult" or
               (is_binary(block_reason) and
                  String.contains?(String.downcase(block_reason), "adult")),
             do: 1,
             else: 0

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

        if is_integer(blocklist_id) and status == "blocked" do
          :ets.insert_new(
            @dns_metrics_table,
            {{:blocklist, config_id, blocklist_id, hour_timestamp}, 0}
          )

          :ets.update_counter(
            @dns_metrics_table,
            {:blocklist, config_id, blocklist_id, hour_timestamp},
            {2, 1}
          )
        end
      end)

      # 3. Broadcast
      if :erlang.whereis(Hermit.PubSub) != :undefined do
        # Broadcast batch log theo profile
        logs_to_flush
        |> Enum.group_by(fn {_, config_id, _, _} -> config_id end)
        |> Enum.each(fn {config_id, group} ->
          logs = Enum.map(group, &elem(&1, 0))

          Phoenix.PubSub.broadcast(
            Hermit.PubSub,
            "dns_logs_profile:#{config_id}",
            {:dns_logs_batch, logs}
          )

          # Đồng thời gửi tin lẻ để đảm bảo tương thích ngược nếu có chỗ khác lắng nghe
          Enum.each(logs, fn log_data ->
            Phoenix.PubSub.broadcast(
              Hermit.PubSub,
              "dns_logs_profile:#{config_id}",
              {:dns_log, log_data}
            )
          end)
        end)

        # Broadcast batch log theo pair_id
        logs_to_flush
        |> Enum.group_by(fn {log_data, _, _, _} -> log_data["pair_id"] end)
        |> Enum.each(fn {pair_id, group} ->
          logs = Enum.map(group, &elem(&1, 0))
          Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{pair_id}", {:dns_logs_batch, logs})

          # Đồng thời gửi tin lẻ để đảm bảo tương thích ngược nếu có chỗ khác lắng nghe
          Enum.each(logs, fn log_data ->
            Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{pair_id}", {:dns_log, log_data})
          end)
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
      {{{:"$1", :"$2"}, :_, :_, :_, :_, :_, :_, :_}, [{:<, :"$2", cutoff_ram_time}], [true]},
      {{{:blocklist, :"$1", :"$2", :"$3"}, :"$4"}, [{:<, :"$3", cutoff_ram_time}], [true]}
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

      Repo.delete_all(
        from(s in Hermit.Dns.BlocklistHourlyStat, where: s.hour_timestamp < ^cutoff_db_time)
      )

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

      {client_ip, _is_doh, doh_device_name} =
        case client_ip_raw do
          {:doh, ip, dev_name} -> {ip, true, dev_name}
          {:doh, ip} -> {ip, true, nil}
          ip -> {ip, false, nil}
        end

      domain = Map.get(metadata, :domain)
      qtype = Map.get(metadata, :qtype)
      status = Map.get(metadata, :status)
      answer = Map.get(metadata, :answer)
      resolver = Map.get(metadata, :resolver)
      block_reason = Map.get(metadata, :block_reason)
      blocklist_id = Map.get(metadata, :blocklist_id)

      pair_id = to_string(profile_id)
      client_ip_str = ip_to_string(client_ip)

      endpoint_id =
        cond do
          is_integer(profile_id) ->
            profile_id

          is_binary(profile_id) ->
            case Integer.parse(profile_id) do
              {id, ""} -> id
              _ -> nil
            end

          true ->
            nil
        end

      endpoint_name =
        if endpoint_id && :ets.info(:inbound_profiles_cache) != :undefined do
          case :ets.lookup(:inbound_profiles_cache, {:endpoint_name, endpoint_id}) do
            [{_, name}] -> name
            _ -> "Unknown"
          end
        else
          # Fallback if table doesn't exist or profile_id is not integer-like
          "Unknown"
        end

      client_name =
        cond do
          doh_device_name && doh_device_name != "" ->
            doh_device_name

          true ->
            Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip_str)
        end

      log_data = %{
        "pair_id" => pair_id,
        "client_ip" => client_ip_str,
        "client_name" => client_name || client_ip_str,
        "endpoint_name" => endpoint_name,
        "domain" => domain,
        "type" => Packet.qtype_to_string(qtype),
        "status" => status,
        "answer" => answer,
        "resolver" => resolver,
        "duration_ms" => duration,
        "timestamp" => System.system_time(:second)
      }

      GenServer.cast(__MODULE__, {:enqueue_log, log_data, config_id, block_reason, blocklist_id})
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

        :ets.insert(@dns_metrics_table, record)
      end)

      # Restore blocklist stats
      blocklist_stats =
        Repo.all(
          from(s in Hermit.Dns.BlocklistHourlyStat, where: s.hour_timestamp >= ^cutoff_time)
        )

      Enum.each(blocklist_stats, fn stat ->
        :ets.insert(
          @dns_metrics_table,
          {{:blocklist, stat.dns_config_id, stat.dns_blocklist_id, stat.hour_timestamp},
           stat.blocked_count}
        )
      end)

      Logger.info(
        "Telemetry: Successfully restored #{length(stats)} hourly metrics from database."
      )
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
        {{config_id, hour_timestamp}, total, blocked, ipv6, adguard, goodbyeads, adult, custom}
        when is_integer(config_id) ->
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
                   on_conflict:
                     {:replace,
                      [
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
                Logger.warning(
                  "Telemetry: Failed to sync hourly metrics to SQLite: #{inspect(changeset.errors)}"
                )
            end
          end

        {{:blocklist, config_id, blocklist_id, hour_timestamp}, count} ->
          if MapSet.member?(active_ids_set, config_id) do
            stat_attrs = %{
              dns_config_id: config_id,
              dns_blocklist_id: blocklist_id,
              hour_timestamp: hour_timestamp,
              blocked_count: count
            }

            changeset =
              %Hermit.Dns.BlocklistHourlyStat{}
              |> Hermit.Dns.BlocklistHourlyStat.changeset(stat_attrs)

            case Repo.insert(
                   changeset,
                   on_conflict: {:replace, [:blocked_count, :updated_at]},
                   conflict_target: [:dns_config_id, :dns_blocklist_id, :hour_timestamp]
                 ) do
              {:ok, _} ->
                :ok

              {:error, changeset} ->
                Logger.warning(
                  "Telemetry: Failed to sync blocklist hourly metrics to SQLite: #{inspect(changeset.errors)}"
                )
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

  defp prune_logs(id) do
    pattern = {{id, :"$1"}, :_}
    # counters are already in ascending order because of :ordered_set select
    counters = :ets.select(@dns_log_table, [{pattern, [], [:"$1"]}])
    count = length(counters)

    if count > @max_raw_logs do
      delete_count = count - @max_raw_logs
      max_deleted_counter = Enum.at(counters, delete_count - 1)

      # Batch delete all records with counter <= max_deleted_counter using select_delete
      :ets.select_delete(@dns_log_table, [
        {{{id, :"$1"}, :_}, [{:"=<", :"$1", max_deleted_counter}], [true]}
      ])
    else
      0
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
