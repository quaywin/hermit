defmodule Hermit.Dns.BlocklistLoader do
  use GenServer
  require Logger

  @adguard_table :adguard_blocklist
  @goodbyeads_table :goodbyeads_blocklist
  @dns_cache_table :dns_cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create ETS tables with read_concurrency to optimize concurrent DNS queries
    :ets.new(@adguard_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@goodbyeads_table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@dns_cache_table, [:set, :public, :named_table, read_concurrency: true])

    # Load blocklists asynchronously to not block application startup
    send(self(), :load_blocklists)

    # Schedule periodic cache pruning every 60 seconds
    :erlang.send_after(60_000, self(), :prune_cache)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_blocklists, state) do
    load_adguard()
    load_goodbyeads()
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune_cache, state) do
    now = System.monotonic_time(:second)
    # Delete all expired entries from :dns_cache
    # Structure: {{profile_id, domain, qtype}, resp_packet, expires_at}
    :ets.select_delete(:dns_cache, [{{{:_, :_, :_}, :_, :"$1"}, [{:<, :"$1", now}], [true]}])

    :erlang.send_after(60_000, self(), :prune_cache)
    {:noreply, state}
  end

  defp load_adguard do
    path = Path.join(:code.priv_dir(:hermit), "dns_blocklists/adguard_dns.txt")
    Logger.info("Starting loading AdGuard DNS Filter from #{path}...")
    start_time = System.monotonic_time()

    if File.exists?(path) do
      count =
        path
        |> File.stream!([:read_ahead])
        |> Stream.map(&String.trim/1)
        |> Stream.map(&parse_adguard_line/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.chunk_every(5000)
        |> Stream.map(fn chunk ->
          entries = Enum.map(chunk, &{&1, true})
          :ets.insert(@adguard_table, entries)
          length(entries)
        end)
        |> Enum.sum()

      duration =
        System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Logger.info("Loaded #{count} domains into AdGuard DNS Filter in #{duration}ms")
    else
      Logger.warning("AdGuard DNS Filter file not found at #{path}")
    end
  end

  defp load_goodbyeads do
    path = Path.join(:code.priv_dir(:hermit), "dns_blocklists/goodbye_ads.txt")
    Logger.info("Starting loading GoodbyeAds Filter from #{path}...")
    start_time = System.monotonic_time()

    if File.exists?(path) do
      count =
        path
        |> File.stream!([:read_ahead])
        |> Stream.map(&String.trim/1)
        |> Stream.map(&parse_hosts_line/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.chunk_every(5000)
        |> Stream.map(fn chunk ->
          entries = Enum.map(chunk, &{&1, true})
          :ets.insert(@goodbyeads_table, entries)
          length(entries)
        end)
        |> Enum.sum()

      duration =
        System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Logger.info("Loaded #{count} domains into GoodbyeAds Filter in #{duration}ms")
    else
      Logger.warning("GoodbyeAds Filter file not found at #{path}")
    end
  end

  # Format: ||domain.com^ (with optional suffix like $third-party)
  defp parse_adguard_line("||" <> rest) do
    case String.split(rest, "^", parts: 2) do
      [domain, _] ->
        clean_domain(domain)

      _ ->
        nil
    end
  end

  defp parse_adguard_line(_), do: nil

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

  defp clean_domain(domain) do
    domain = String.downcase(domain)
    # Basic validation to ensure it looks like a domain
    if String.match?(domain, ~r/^[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,50}$/) do
      domain
    else
      nil
    end
  end
end
