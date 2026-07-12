defmodule Hermit.Dns.BlocklistLoader do
  use GenServer
  require Logger
  alias Hermit.Repo
  alias Hermit.Dns.Blocklist

  @dns_cache_table :dns_cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create unified ETS table with read_concurrency to optimize concurrent DNS queries
    :ets.new(:dns_blocklist_entries, [:bag, :public, :named_table, read_concurrency: true])

    :ets.new(@dns_cache_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    :ets.new(:dns_filter_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    :ets.new(:inbound_profiles_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    :ets.new(:dns_proxy_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    # Load blocklists asynchronously to not block application startup
    send(self(), :load_blocklists)

    # Schedule periodic cache pruning every 60 seconds
    :erlang.send_after(60_000, self(), :prune_cache)

    state = %{update_timer: nil}
    state = schedule_next_update(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:load_blocklists, state) do
    # Run blocklist reloading in a background task to prevent freezing the GenServer during boot
    Task.start(fn -> reload_all() end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune_cache, state) do
    now = System.monotonic_time(:second)
    # Delete all expired entries from :dns_cache
    :ets.select_delete(:dns_cache, [
      {{{:_, :_, :_}, :_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    # Prune dns_filter_cache if too large to prevent memory leak
    if :ets.info(:dns_filter_cache) != :undefined and :ets.info(:dns_filter_cache, :size) > 50_000 do
      :ets.delete_all_objects(:dns_filter_cache)
    end

    :erlang.send_after(60_000, self(), :prune_cache)
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_update, state) do
    Logger.info("Starting scheduled periodic update of DNS blocklists...")
    # Run blocklist reloading in a background task to prevent freezing the GenServer during update
    Task.start(fn -> reload_all() end)
    state = schedule_next_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:reschedule_update, _interval}, state) do
    state = schedule_next_update(state)
    {:noreply, state}
  end

  @doc """
  Returns the memory usage of the blocklist ETS table as a formatted string.
  """
  def get_memory_usage do
    case :ets.info(:dns_blocklist_entries, :memory) do
      :undefined ->
        "0 KB"

      words ->
        bytes = words * :erlang.system_info(:wordsize)

        cond do
          bytes >= 1024 * 1024 ->
            "#{Float.round(bytes / (1024 * 1024), 2)} MB"

          bytes >= 1024 ->
            "#{Float.round(bytes / 1024, 1)} KB"

          true ->
            "#{bytes} B"
        end
    end
  end

  @doc """
  Reloads all enabled blocklists from the database into the ETS table.
  """
  def reload_all do
    try do
      if Repo.aggregate(Blocklist, :count) > 0 do
        Blocklist
        |> Repo.all()
        |> Enum.filter(& &1.enabled)
        # Load blocklists in parallel with max concurrency of 4 to utilize cores and reduce I/O time
        |> Task.async_stream(&load_blocklist/1, max_concurrency: 4, timeout: 120_000)
        |> Stream.run()
      else
        Logger.warning("No DNS blocklists found in database to load.")
      end
    rescue
      e ->
        Logger.error("Failed to load blocklists from database: #{inspect(e)}")
    end
  end

  @doc """
  Loads a specific blocklist into the unified ETS table.
  """
  def load_blocklist(%Blocklist{} = blocklist) do
    Logger.info("Starting loading Blocklist '#{blocklist.name}' from #{blocklist.url}...")
    start_time = System.monotonic_time()

    # Clean old entries for this blocklist first
    :ets.select_delete(:dns_blocklist_entries, [{{:_, blocklist.id}, [], [true]}])

    case get_lines(blocklist.url) do
      {:ok, line_stream_or_enum} ->
        count =
          line_stream_or_enum
          |> Stream.map(&String.trim/1)
          |> Stream.map(fn line ->
            case blocklist.format do
              "adguard" -> parse_adguard_line(line)
              "hosts" -> parse_hosts_line(line)
              "domains" -> parse_domains_line(line)
              _ -> nil
            end
          end)
          |> Stream.reject(&is_nil/1)
          |> Stream.chunk_every(5000)
          |> Stream.map(fn chunk ->
            entries = Enum.map(chunk, &{&1, blocklist.id})
            :ets.insert(:dns_blocklist_entries, entries)
            length(entries)
          end)
          |> Enum.sum()

        duration =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        Logger.info("Loaded #{count} domains into Blocklist '#{blocklist.name}' in #{duration}ms")

        # Update rules count and timestamp in DB without triggering callbacks
        update_rules_count(blocklist.id, count)

        # Store metadata in ETS
        :ets.insert(:dns_blocklist_entries, {{:metadata, blocklist.id}, blocklist.name})

      {:error, reason} ->
        Logger.error("Failed to load Blocklist '#{blocklist.name}': #{inspect(reason)}")
    end
  end

  @doc """
  Triggers a background task to load a specific blocklist so it doesn't block calling process.
  """
  def load_blocklist_async(blocklist) do
    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
      load_blocklist(blocklist)
    end)
  end

  @doc """
  Unloads a specific blocklist from the ETS table.
  """
  def unload_blocklist(blocklist_id) do
    :ets.select_delete(:dns_blocklist_entries, [{{:_, blocklist_id}, [], [true]}])
    :ets.delete(:dns_blocklist_entries, {:metadata, blocklist_id})

    # Clear DNS caches for all profiles using this blocklist
    clear_cache_for_blocklist(blocklist_id)
  end

  defp update_rules_count(blocklist_id, count) do
    import Ecto.Query
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.update_all(
      from(b in Blocklist, where: b.id == ^blocklist_id),
      set: [rules_count: count, last_fetched_at: now, updated_at: now]
    )

    # Clear DNS caches for all profiles using this blocklist
    clear_cache_for_blocklist(blocklist_id)

    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_blocklist", {:blocklist_updated, blocklist_id})
    end
  end

  @doc """
  Clears the DNS filter result cache.
  """
  def clear_filter_cache do
    if :ets.info(:dns_filter_cache) != :undefined do
      :ets.delete_all_objects(:dns_filter_cache)
    end
  end

  defp clear_cache_for_blocklist(blocklist_id) do
    clear_filter_cache()
    import Ecto.Query
    # Find all inbound profiles using a DNS config that contains this blocklist
    inbound_profile_ids =
      Repo.all(
        from(ip in Hermit.Vpn.InboundProfile,
          join: dc in assoc(ip, :dns_profile),
          join: b in assoc(dc, :blocklists),
          where: b.id == ^blocklist_id,
          select: ip.id
        )
      )

    Enum.each(inbound_profile_ids, fn ip_id ->
      Logger.info(
        "Blocklist #{blocklist_id} updated/unloaded. Clearing DNS cache for inbound profile #{ip_id}."
      )

      Hermit.Dns.Cache.clear(ip_id)
    end)
  rescue
    e ->
      Logger.error("Failed to clear DNS cache for blocklist #{blocklist_id}: #{inspect(e)}")
  end

  defp fetch_content(url) do
    headers = [
      {"user-agent",
       "Mozilla/5.0 (compatible; HermitDNS/0.1.0; +https://github.com/kipcole9/dns)"}
    ]

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_lines(url) do
    cond do
      String.starts_with?(url, ["http://", "https://"]) ->
        case fetch_content(url) do
          {:ok, body} -> {:ok, String.split(body, ["\r\n", "\n"])}
          {:error, reason} -> {:error, reason}
        end

      true ->
        resolved = resolve_path(url)

        if File.exists?(resolved) do
          {:ok, File.stream!(resolved, [:read_ahead])}
        else
          {:error, "File not found at #{resolved}"}
        end
    end
  end

  defp resolve_path("priv/" <> rest) do
    Path.join(:code.priv_dir(:hermit), rest)
  end

  defp resolve_path(path), do: path

  # Format: ||domain.com^ (with optional suffix like $third-party)
  defp parse_adguard_line("||" <> rest) do
    case String.split(rest, "^", parts: 2) do
      [domain, _] ->
        clean_domain(domain)

      _ ->
        nil
    end
  end

  # Format: ||domain.com^ (with optional modifiers after ^, e.g. ||domain.com^$third-party)
  defp parse_adguard_line(line) do
    if String.starts_with?(line, "||") do
      # Remove leading ||
      rest = String.slice(line, 2..-1//-1)
      # Find the index of the first carat ^
      case :binary.match(rest, "^") do
        {idx, _len} ->
          domain = binary_part(rest, 0, idx)
          clean_domain(domain)

        :nomatch ->
          nil
      end
    else
      nil
    end
  end

  # Format: 0.0.0.0 domain.com or 127.0.0.1 domain.com
  defp parse_hosts_line(line) do
    if String.starts_with?(line, ["#", "!"]) or line == "" do
      nil
    else
      parts = String.split(line, ~r/\s+/, trim: true)

      case parts do
        [ip, domain | _] when ip in ["0.0.0.0", "127.0.0.1"] ->
          clean_domain(domain)

        _ ->
          nil
      end
    end
  end

  # Format: plain domains, one per line. Ignore comments starting with # or !
  defp parse_domains_line(line) do
    if String.starts_with?(line, ["#", "!"]) or line == "" do
      nil
    else
      clean_domain(line)
    end
  end

  defp clean_domain(domain) do
    domain = String.downcase(domain)
    # Basic validation to ensure it looks like a domain
    if String.match?(domain, ~r/^[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,50}$/) do
      domain
    else
      nil
    end
  end

  defp schedule_next_update(state) do
    if state[:update_timer] do
      :erlang.cancel_timer(state.update_timer)
    end

    interval_str = Hermit.Vpn.Setting.get_value("dns_blocklist_auto_update_interval", "24h")

    case interval_str do
      "disabled" ->
        Map.put(state, :update_timer, nil)

      interval ->
        ms = parse_interval_to_ms(interval)
        timer = :erlang.send_after(ms, self(), :periodic_update)
        Map.put(state, :update_timer, timer)
    end
  end

  defp parse_interval_to_ms("12h"), do: 12 * 3600 * 1000
  defp parse_interval_to_ms("24h"), do: 24 * 3600 * 1000
  defp parse_interval_to_ms("7d"), do: 7 * 24 * 3600 * 1000
  defp parse_interval_to_ms(_), do: 24 * 3600 * 1000

  @doc """
  Returns the available system memory as a formatted string.
  """
  def get_system_free_memory_string do
    case get_system_memory_info() do
      {:ok, bytes} ->
        cond do
          bytes >= 1024 * 1024 * 1024 ->
            "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

          bytes >= 1024 * 1024 ->
            "#{Float.round(bytes / (1024 * 1024), 1)} MB"

          true ->
            "#{Float.round(bytes / 1024, 0)} KB"
        end

      _ ->
        "N/A"
    end
  end

  defp get_system_memory_info do
    case :os.type() do
      {:unix, :darwin} ->
        get_mac_available_memory()

      {:unix, :linux} ->
        get_linux_available_memory()

      _ ->
        {:error, "Unsupported OS"}
    end
  end

  defp get_linux_available_memory do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        mem_available =
          content
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ~r/\s+/) do
              ["MemAvailable:", kb_str, "kB"] -> String.to_integer(kb_str) * 1024
              _ -> nil
            end
          end)

        if mem_available do
          {:ok, mem_available}
        else
          mem_free =
            content
            |> String.split("\n")
            |> Enum.find_value(fn line ->
              case String.split(line, ~r/\s+/) do
                ["MemFree:", kb_str, "kB"] -> String.to_integer(kb_str) * 1024
                _ -> nil
              end
            end)

          if mem_free, do: {:ok, mem_free}, else: {:error, "Could not parse /proc/meminfo"}
        end

      {:error, _} ->
        {:error, "Could not read /proc/meminfo"}
    end
  end

  defp get_mac_available_memory do
    case System.shell("vm_stat") do
      {output, 0} ->
        page_size = 4096

        free_pages =
          output
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ~r/:\s+/) do
              ["Pages free", count_str] ->
                count_str |> String.trim_trailing(".") |> String.trim() |> String.to_integer()

              _ ->
                nil
            end
          end)

        inactive_pages =
          output
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ~r/:\s+/) do
              ["Pages inactive", count_str] ->
                count_str |> String.trim_trailing(".") |> String.trim() |> String.to_integer()

              _ ->
                nil
            end
          end)

        if free_pages do
          total_pages = free_pages + (inactive_pages || 0)
          {:ok, total_pages * page_size}
        else
          {:error, "Could not parse vm_stat"}
        end

      _ ->
        {:error, "Failed to run vm_stat"}
    end
  end
end
