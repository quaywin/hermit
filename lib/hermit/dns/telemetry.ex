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

  @doc """
  Ensures that the telemetry handler is attached.
  Self-healing mechanism in case the handler was ever detached.
  """
  def ensure_attached do
    handlers = :telemetry.list_handlers([:hermit, :dns, :query])

    if not Enum.any?(handlers, fn h -> h.id == "hermit-dns-queries" end) do
      case :telemetry.attach(
             "hermit-dns-queries",
             [:hermit, :dns, :query],
             &__MODULE__.handle_event/4,
             nil
           ) do
        :ok ->
          Logger.info("Telemetry: Attached 'hermit-dns-queries' handler.")

        {:error, :already_exists} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Telemetry: Failed to attach 'hermit-dns-queries' handler: #{inspect(reason)}"
          )
      end
    end
  end

  @doc """
  Returns a 24-hour summary of DNS metrics (total queries, blocked queries, block rate, and hourly series).
  Fast and memory-efficient: reads directly from the RAM ETS metrics table with SQLite fallback.
  """
  def get_24h_summary do
    now = System.system_time(:second)
    current_hour = div(now, 3600) * 3600
    cutoff = current_hour - 23 * 3600

    ets_stats =
      if :ets.info(@dns_metrics_table) != :undefined do
        :ets.tab2list(@dns_metrics_table)
        |> Enum.reduce(%{}, fn
          {{_config_id, hour_ts}, total, blocked, _ipv6, _upstream, _custom}, acc
          when hour_ts >= cutoff ->
            Map.update(acc, hour_ts, {total, blocked}, fn {cur_tot, cur_blk} ->
              {cur_tot + total, cur_blk + blocked}
            end)

          _, acc ->
            acc
        end)
      else
        %{}
      end

    stats_map =
      if map_size(ets_stats) > 0 do
        ets_stats
      else
        try do
          from(s in HourlyStat,
            where: s.hour_timestamp >= ^cutoff,
            select: {s.hour_timestamp, s.total_queries, s.blocked_queries}
          )
          |> Repo.all()
          |> Enum.reduce(%{}, fn {hour_ts, total, blocked}, acc ->
            Map.update(acc, hour_ts, {total, blocked}, fn {cur_tot, cur_blk} ->
              {cur_tot + total, cur_blk + blocked}
            end)
          end)
        rescue
          _ -> %{}
        catch
          _, _ -> %{}
        end
      end

    hourly_series =
      for i <- 23..0//-1 do
        hour_ts = current_hour - i * 3600
        {tot, blk} = Map.get(stats_map, hour_ts, {0, 0})
        dt = DateTime.from_unix!(hour_ts)
        label = Calendar.strftime(dt, "%H:00")
        %{hour_label: label, hour_ts: hour_ts, total: tot, blocked: blk}
      end

    total_queries = Enum.reduce(hourly_series, 0, fn h, acc -> acc + h.total end)
    blocked_queries = Enum.reduce(hourly_series, 0, fn h, acc -> acc + h.blocked end)
    block_rate = if total_queries > 0, do: round(blocked_queries / total_queries * 100), else: 0

    %{
      total_queries: total_queries,
      blocked_queries: blocked_queries,
      block_rate: block_rate,
      hourly_series: hourly_series
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    if :ets.info(@dns_log_table) == :undefined do
      :ets.new(@dns_log_table, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])
    end

    if :ets.info(@dns_metrics_table) == :undefined do
      :ets.new(@dns_metrics_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])
    end

    ensure_attached()

    :erlang.send_after(60_000, self(), :periodic_prune)
    :erlang.send_after(1000, self(), :flush_logs)
    :erlang.send_after(5000, self(), :daily_db_cleanup)

    {:ok, %{log_buffer: [], cached_config_ids: [], last_config_fetch_at: 0}}
  end

  @impl true
  def handle_cast({:enqueue_log, log_data, config_id, block_reason}, state) do
    log_buffer = [{log_data, config_id, block_reason} | state.log_buffer]
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
      try do
        logs_to_flush = Enum.reverse(state.log_buffer)

        # 1. Bulk insert to ETS
        ets_entries =
          Enum.flat_map(logs_to_flush, fn {log_data, config_id, _} ->
            pair_id = log_data["pair_id"]
            counter = System.unique_integer([:monotonic])

            cfg_key = if is_nil(config_id), do: "fallback", else: config_id
            pair_key = if pair_id in [nil, ""], do: "fallback", else: pair_id

            [
              {{pair_key, counter}, log_data},
              {{cfg_key, counter}, log_data}
            ]
          end)

        :ets.insert(@dns_log_table, ets_entries)

        # 2. Hourly stats metrics
        Enum.each(logs_to_flush, fn {log_data, config_id, block_reason} ->
          hour_timestamp = div(log_data["timestamp"], 3600) * 3600
          status = log_data["status"]

          :ets.insert_new(@dns_metrics_table, {{config_id, hour_timestamp}, 0, 0, 0, 0, 0})

          is_blocked = if status == "blocked", do: 1, else: 0
          is_ipv6_blocked = if block_reason == "ipv6", do: 1, else: 0
          is_upstream = if block_reason == "upstream_filter", do: 1, else: 0
          is_custom = if block_reason == "custom_rule", do: 1, else: 0

          updates = [
            {2, 1},
            {3, is_blocked},
            {4, is_ipv6_blocked},
            {5, is_upstream},
            {6, is_custom}
          ]

          :ets.update_counter(@dns_metrics_table, {config_id, hour_timestamp}, updates)
        end)

        now = System.system_time(:second)

        {cached_config_ids, last_config_fetch_at} =
          if now - Map.get(state, :last_config_fetch_at, 0) >= 60 or
               Map.get(state, :cached_config_ids, []) == [] do
            ids =
              try do
                Repo.all(from(d in Hermit.Vpn.DnsConfig, select: d.id))
              rescue
                _ -> Map.get(state, :cached_config_ids, [])
              catch
                _, _ -> Map.get(state, :cached_config_ids, [])
              end

            {ids, now}
          else
            {Map.get(state, :cached_config_ids, []), Map.get(state, :last_config_fetch_at, 0)}
          end

        # 3. Broadcast
        if :erlang.whereis(Hermit.PubSub) != :undefined do
          logs_to_flush
          |> Enum.group_by(fn {_, config_id, _} -> config_id end)
          |> Enum.each(fn {config_id, group} ->
            logs = Enum.map(group, &elem(&1, 0))

            if config_id do
              Phoenix.PubSub.broadcast(
                Hermit.PubSub,
                "dns_logs_profile:#{config_id}",
                {:dns_logs_batch, logs}
              )
            else
              Enum.each(cached_config_ids, fn cfg_id ->
                Phoenix.PubSub.broadcast(
                  Hermit.PubSub,
                  "dns_logs_profile:#{cfg_id}",
                  {:dns_logs_batch, logs}
                )
              end)
            end
          end)

          logs_to_flush
          |> Enum.group_by(fn {log_data, _, _} -> log_data["pair_id"] end)
          |> Enum.each(fn {pair_id, group} ->
            logs = Enum.map(group, &elem(&1, 0))

            Phoenix.PubSub.broadcast(
              Hermit.PubSub,
              "dns_logs:#{pair_id}",
              {:dns_logs_batch, logs}
            )
          end)
        end

        {:noreply,
         %{
           state
           | log_buffer: [],
             cached_config_ids: cached_config_ids,
             last_config_fetch_at: last_config_fetch_at
         }}
      rescue
        e ->
          Logger.warning(
            "Telemetry: Error during flush_logs: #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          {:noreply, %{state | log_buffer: []}}
      catch
        kind, reason ->
          Logger.warning(
            "Telemetry: Exit during flush_logs: #{Exception.format(kind, reason, __STACKTRACE__)}"
          )

          {:noreply, %{state | log_buffer: []}}
      end
    end
  end

  @impl true
  def handle_info(:periodic_prune, state) do
    :erlang.send_after(60_000, self(), :periodic_prune)
    ensure_attached()

    try do
      pair_ids = collect_pair_ids(@dns_log_table)

      Enum.each(pair_ids, fn pair_id ->
        prune_logs(pair_id)
      end)

      sync_metrics_to_db()

      cutoff_ram_time = System.system_time(:second) - 24 * 3600

      :ets.select_delete(@dns_metrics_table, [
        {{{:"$1", :"$2"}, :_, :_, :_, :_, :_}, [{:<, :"$2", cutoff_ram_time}], [true]}
      ])
    rescue
      e ->
        Logger.warning("Telemetry: Error during periodic_prune: #{inspect(e)}")
    catch
      kind, reason ->
        Logger.warning("Telemetry: Exit during periodic_prune: #{inspect({kind, reason})}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:daily_db_cleanup, state) do
    cutoff_db_time = System.system_time(:second) - 30 * 24 * 3600

    try do
      Repo.delete_all(from(s in HourlyStat, where: s.hour_timestamp < ^cutoff_db_time))
      Logger.info("Telemetry: Successfully pruned old SQLite metrics.")
    rescue
      e -> Logger.warning("Telemetry: Failed to prune old SQLite metrics: #{inspect(e)}")
    end

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
  Wrapped with try/rescue so that under no circumstances does it raise and cause :telemetry to detach it.
  """
  def handle_event([:hermit, :dns, :query], measurements, metadata, _config) do
    if Map.get(metadata, :enable_query_logging, false) do
      try do
        duration = Map.get(measurements, :duration)
        profile_id = Map.get(metadata, :profile_id)
        config_id = Map.get(metadata, :config_id)
        client_ip = Map.get(metadata, :client_ip)

        domain = Map.get(metadata, :domain)
        qtype = Map.get(metadata, :qtype)
        status = Map.get(metadata, :status)
        answer = Map.get(metadata, :answer)
        resolver = Map.get(metadata, :resolver)
        block_reason = Map.get(metadata, :block_reason)

        pair_id = if is_nil(profile_id), do: "", else: to_string(profile_id)
        client_ip_str = Packet.ip_to_string(client_ip)

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
          cond do
            Map.get(metadata, :endpoint_name) ->
              Map.get(metadata, :endpoint_name)

            endpoint_id && :ets.info(:inbound_profiles_cache) != :undefined ->
              case :ets.lookup(:inbound_profiles_cache, {:endpoint_name, endpoint_id}) do
                [{_, name}] -> name
                _ -> "Endpoint #{endpoint_id}"
              end

            true ->
              "Unknown Endpoint"
          end

        client_name = Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip_str)

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

        GenServer.cast(
          __MODULE__,
          {:enqueue_log, log_data, config_id, block_reason}
        )
      rescue
        e ->
          Logger.warning(
            "Telemetry: handle_event error (prevented detachment): #{Exception.format(:error, e, __STACKTRACE__)}"
          )

          :ok
      catch
        kind, reason ->
          Logger.warning(
            "Telemetry: handle_event exit (prevented detachment): #{Exception.format(kind, reason, __STACKTRACE__)}"
          )

          :ok
      end
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

        upstream =
          stat.upstream_blocked_count + stat.adguard_blocked_count +
            stat.goodbyeads_blocked_count + stat.adult_blocked_count

        record = {
          {config_id, hour_timestamp},
          stat.total_queries,
          stat.blocked_queries,
          stat.ipv6_blocked_count,
          upstream,
          stat.custom_blocked_count
        }

        :ets.insert(@dns_metrics_table, record)
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

      Repo.transaction(fn ->
        Enum.each(records, fn
          {{config_id, hour_timestamp}, total, blocked, ipv6, upstream, custom}
          when is_integer(config_id) ->
            if MapSet.member?(active_ids_set, config_id) do
              stat_attrs = %{
                dns_config_id: config_id,
                hour_timestamp: hour_timestamp,
                total_queries: total,
                blocked_queries: blocked,
                ipv6_blocked_count: ipv6,
                upstream_blocked_count: upstream,
                custom_blocked_count: custom
              }

              changeset = %HourlyStat{} |> HourlyStat.changeset(stat_attrs)

              case Repo.insert(
                     changeset,
                     on_conflict:
                       {:replace,
                        [
                          :total_queries,
                          :blocked_queries,
                          :ipv6_blocked_count,
                          :upstream_blocked_count,
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

          _ ->
            :ok
        end)
      end)
    rescue
      e -> Logger.warning("Telemetry: Failed to sync hourly metrics to SQLite: #{inspect(e)}")
    catch
      _, _ -> :ok
    end
  end

  # --- General helper functions ---

  defp prune_logs(id) do
    pattern = {{id, :"$1"}, :_}
    counters = :ets.select(@dns_log_table, [{pattern, [], [:"$1"]}])
    count = length(counters)

    if count > @max_raw_logs do
      delete_count = count - @max_raw_logs
      max_deleted_counter = Enum.at(counters, delete_count - 1)

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
