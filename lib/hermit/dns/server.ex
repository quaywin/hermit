defmodule Hermit.Dns.Server do
  use GenServer
  require Logger
  alias Hermit.Dns.Packet

  @table :dns_query_logs

  # Lightweight built-in filters

  @adult_domains MapSet.new([
                   "pornhub.com",
                   "xvideos.com",
                   "xnxx.com",
                   "redtube.com",
                   "youporn.com",
                   "chaturbate.com",
                   "stripchat.com",
                   "livejasmin.com",
                   "onlyfans.com"
                 ])

  def start_link(opts) do
    profile_id = opts[:profile_id]
    name = {:via, Registry, {Hermit.Vpn.Registry, {:dns_server, profile_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    port = opts[:port]
    profile_id = opts[:profile_id]

    state = %{
      socket: nil,
      port: port,
      profile_id: profile_id,
      upstreams_map: %{},
      active_upstream: nil
    }

    case try_bind_socket(state) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, _reason, new_state} ->
        :erlang.send_after(1000, self(), :retry_bind)
        {:ok, new_state}
    end
  end

  defp try_bind_socket(%{profile_id: profile_id, port: port} = state) do
    bind_opts =
      if mock?() do
        [:binary, active: true, reuseaddr: true]
      else
        [:binary, active: true, reuseaddr: true, ip: {10, 251, profile_id, 1}]
      end

    case :gen_udp.open(port, bind_opts) do
      {:ok, socket} ->
        Logger.info("Elixir DNS Server for profile #{profile_id} listening on UDP port #{port}")
        # Start periodic active probing timer
        :erlang.send_after(30_000, self(), :active_probe)
        {:ok, %{state | socket: socket}}

      {:error, reason} ->
        Logger.warning(
          "Failed to start Elixir DNS Server for profile #{profile_id} on port #{port}: #{inspect(reason)}. Will retry..."
        )

        {:error, reason, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{socket: socket} = state) do
    case Packet.parse(packet) do
      {:ok, query} ->
        # process_query_fast_path returns the updated state containing synced upstreams
        new_state = process_query_fast_path(socket, ip, port, packet, query, state)
        {:noreply, new_state}

      {:error, _reason} ->
        if byte_size(packet) >= 12 do
          <<id::binary-size(2), _::binary>> = packet
          err_resp = <<id::binary, 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
          :gen_udp.send(socket, ip, port, err_resp)
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:active_probe, state) do
    :erlang.send_after(30_000, self(), :active_probe)
    upstreams = Map.keys(state.upstreams_map)
    server_pid = self()

    if length(upstreams) > 0 do
      # Smallest possible query: NS query for root domain "." (17 bytes)
      probe_packet =
        <<0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          0x02, 0x00, 0x01>>

      Task.start(fn ->
        Enum.each(upstreams, fn upstream ->
          case query_upstream(upstream, probe_packet) do
            {:ok, _resp, duration} ->
              GenServer.cast(server_pid, {:update_latency, upstream, duration})

            _ ->
              GenServer.cast(server_pid, {:update_latency, upstream, 2000})
          end
        end)
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_bind, state) do
    if is_nil(state.socket) do
      case try_bind_socket(state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, _reason, new_state} ->
          :erlang.send_after(1000, self(), :retry_bind)
          {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_latency, upstream, latency}, state) do
    upstreams_map = Map.put(state.upstreams_map, upstream, latency)

    active_upstream =
      if map_size(upstreams_map) > 0 do
        {best_ip, _best_latency} = Enum.min_by(upstreams_map, fn {_ip, lat} -> lat end)
        best_ip
      else
        nil
      end

    {:noreply, %{state | upstreams_map: upstreams_map, active_upstream: active_upstream}}
  end

  # --- DNS Core Processing ---

  defp sync_upstreams_config(state, upstreams) do
    existing_keys = Map.keys(state.upstreams_map)

    if Enum.sort(existing_keys) == Enum.sort(upstreams) do
      state
    else
      upstreams_map =
        Enum.into(upstreams, %{}, fn ip ->
          {ip, Map.get(state.upstreams_map, ip, 20)}
        end)

      active_upstream =
        if map_size(upstreams_map) > 0 do
          {best_ip, _best_latency} = Enum.min_by(upstreams_map, fn {_ip, lat} -> lat end)
          best_ip
        else
          nil
        end

      %{state | upstreams_map: upstreams_map, active_upstream: active_upstream}
    end
  end

  defp process_query_fast_path(socket, ip, port, packet, query, state) do
    start_time = System.monotonic_time()
    client_ip_str = ip_to_string(ip)
    profile_id = state.profile_id
    config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)
    upstreams = parse_upstreams(config.upstream_dns)
    enable_query_logging = config.enable_query_logging

    # Sync state with config upstreams if changed
    state = sync_upstreams_config(state, upstreams)

    # 1. Match custom rules
    custom_rules = get_custom_rules(config.custom_rules)
    {action, redirect_val} = match_custom_rules(query.domain, custom_rules)

    # 2. Match built-in blocklists if not matched by custom rules
    {action, redirect_val} =
      if is_nil(action) and config.enabled do
        cond do
          config.block_ads and match_ets_blocklist?(query.domain, :adguard_blocklist) ->
            {"block", nil}

          config.block_goodbyeads and match_ets_blocklist?(query.domain, :goodbyeads_blocklist) ->
            {"block", nil}

          config.block_adult and match_domain_set?(query.domain, @adult_domains) ->
            {"block", nil}

          true ->
            {nil, nil}
        end
      else
        {action, redirect_val}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    case action do
      "block" ->
        resp = Packet.build_nxdomain(query.id, query.question_section)
        :gen_udp.send(socket, ip, port, resp)

        log_and_broadcast(
          profile_id,
          client_ip_str,
          query.domain,
          query.qtype,
          "blocked",
          "NXDOMAIN",
          duration_ms,
          enable_query_logging
        )

        state

      "redirect" when not is_nil(redirect_val) ->
        if query.qtype == :A do
          resp = Packet.build_a_response(query.id, query.question_section, redirect_val)
          :gen_udp.send(socket, ip, port, resp)

          log_and_broadcast(
            profile_id,
            client_ip_str,
            query.domain,
            query.qtype,
            "redirected",
            redirect_val,
            duration_ms,
            enable_query_logging
          )
        else
          resp = Packet.build_nxdomain(query.id, query.question_section)
          :gen_udp.send(socket, ip, port, resp)

          log_and_broadcast(
            profile_id,
            client_ip_str,
            query.domain,
            query.qtype,
            "redirected",
            "NXDOMAIN",
            duration_ms,
            enable_query_logging
          )
        end

        state

      _ ->
        case lookup_cache(profile_id, query.domain, query.qtype) do
          {:ok, cached_packet} ->
            <<_old_id::binary-size(2), rest_packet::binary>> = cached_packet
            resp_packet = query.id <> rest_packet
            :gen_udp.send(socket, ip, port, resp_packet)

            log_and_broadcast(
              profile_id,
              client_ip_str,
              query.domain,
              query.qtype,
              "resolved",
              "Resolved (cached)",
              duration_ms,
              enable_query_logging
            )

            state

          :error ->
            # Split routing based on domain
            target_upstreams =
              select_upstreams_for_domain(query.domain, upstreams)

            active_upstream = state.active_upstream
            server_pid = self()

            spawn(fn ->
              forward_to_upstream(
                socket,
                ip,
                port,
                packet,
                query,
                client_ip_str,
                target_upstreams,
                active_upstream,
                start_time,
                profile_id,
                server_pid,
                enable_query_logging
              )
            end)

            state
        end
    end
  end

  # Split routing: if domain is domestic, prioritize private/local IP upstreams
  defp select_upstreams_for_domain(domain, upstreams) do
    cond do
      is_tailscale_domain?(domain) ->
        # For Tailscale magic DNS domains, prepend Tailscale nameserver 100.100.100.100
        ts_ns = {:udp, {100, 100, 100, 100}}
        [ts_ns | List.delete(upstreams, ts_ns)]

      is_domestic_domain?(domain) ->
        Enum.sort_by(upstreams, fn target ->
          case target do
            {:udp, ip} -> if local_ip?(ip), do: 0, else: 1
            # Put DoH at the bottom for domestic domains
            _ -> 2
          end
        end)

      true ->
        upstreams
    end
  end

  defp is_tailscale_domain?(domain) do
    String.ends_with?(domain, ".ts.net") or
      String.ends_with?(domain, ".tailscale.net")
  end

  defp is_domestic_domain?(domain) do
    String.ends_with?(domain, ".vn") or
      String.ends_with?(domain, ".local") or
      String.ends_with?(domain, ".hermit")
  end

  defp local_ip?({192, 168, _, _}), do: true
  defp local_ip?({10, _, _, _}), do: true
  defp local_ip?({172, idx, _, _}) when idx >= 16 and idx <= 31, do: true
  defp local_ip?({100, idx, _, _}) when idx >= 64 and idx <= 127, do: true
  defp local_ip?(_), do: false

  defp forward_to_upstream(
         socket,
         ip,
         port,
         packet,
         query,
         client_ip_str,
         target_upstreams,
         active_upstream,
         start_time,
         profile_id,
         server_pid,
         enable_query_logging
       ) do
    case try_upstreams_parallel(target_upstreams, active_upstream, packet) do
      {:ok, resp_packet, successful_upstream, duration} ->
        GenServer.cast(server_pid, {:update_latency, successful_upstream, duration})
        store_cache(profile_id, query.domain, query.qtype, resp_packet)
        :gen_udp.send(socket, ip, port, resp_packet)

        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        answer_ip = parse_resolved_ip(resp_packet)

        log_and_broadcast(
          profile_id,
          client_ip_str,
          query.domain,
          query.qtype,
          "resolved",
          answer_ip,
          duration_ms,
          enable_query_logging
        )

      {:error, _} ->
        if active_upstream do
          GenServer.cast(server_pid, {:update_latency, active_upstream, 2000})
        end

        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        servfail = Packet.build_nxdomain(query.id, query.question_section)
        servfail = patch_rcode(servfail, 2)
        :gen_udp.send(socket, ip, port, servfail)

        log_and_broadcast(
          profile_id,
          client_ip_str,
          query.domain,
          query.qtype,
          "resolved",
          "SERVFAIL",
          duration_ms,
          enable_query_logging
        )
    end
  end

  defp patch_rcode(<<id::binary-size(2), _flags::binary-size(2), rest::binary>>, rcode) do
    flags2 = 0x80 + rcode
    <<id::binary, 0x81, flags2, rest::binary>>
  end

  defp try_upstreams_parallel(upstreams, active_upstream, packet) do
    sorted =
      if active_upstream in upstreams do
        [active_upstream | List.delete(upstreams, active_upstream)]
      else
        upstreams
      end

    case sorted do
      [] ->
        {:error, :no_upstreams}

      [single] ->
        case query_upstream(single, packet) do
          {:ok, resp_packet, duration} -> {:ok, resp_packet, single, duration}
          error -> error
        end

      [primary | fallbacks] ->
        primary_task =
          Task.async(fn ->
            case query_upstream(primary, packet) do
              {:ok, resp_packet, duration} -> {:ok, resp_packet, primary, duration}
              error -> error
            end
          end)

        case Task.yield(primary_task, 200) do
          {:ok, {:ok, resp_packet, ^primary, duration}} ->
            Task.shutdown(primary_task, :brutal_kill)
            {:ok, resp_packet, primary, duration}

          {:ok, {:error, _reason}} ->
            Task.shutdown(primary_task, :brutal_kill)
            run_fallback_parallel(fallbacks, packet)

          {:exit, _reason} ->
            Task.shutdown(primary_task, :brutal_kill)
            run_fallback_parallel(fallbacks, packet)

          nil ->
            fallback_tasks =
              Enum.map(fallbacks, fn fallback ->
                Task.async(fn ->
                  case query_upstream(fallback, packet) do
                    {:ok, resp_packet, duration} -> {:ok, resp_packet, fallback, duration}
                    error -> error
                  end
                end)
              end)

            all_tasks = [primary_task | fallback_tasks]
            result = wait_for_first_success(all_tasks, length(all_tasks))

            Enum.each(all_tasks, fn task ->
              Task.shutdown(task, :brutal_kill)
            end)

            result
        end
    end
  end

  defp run_fallback_parallel(fallbacks, packet) do
    tasks =
      Enum.map(fallbacks, fn upstream ->
        Task.async(fn ->
          case query_upstream(upstream, packet) do
            {:ok, resp_packet, duration} -> {:ok, resp_packet, upstream, duration}
            error -> error
          end
        end)
      end)

    result = wait_for_first_success(tasks, length(tasks))

    Enum.each(tasks, fn task ->
      Task.shutdown(task, :brutal_kill)
    end)

    result
  end

  defp query_upstream({:udp, upstream}, packet) do
    start = System.monotonic_time()

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, client_sock} ->
        try do
          case :gen_udp.send(client_sock, upstream, 53, packet) do
            :ok ->
              case :gen_udp.recv(client_sock, 0, 3000) do
                {:ok, {_ip, 53, resp_packet}} ->
                  duration =
                    System.convert_time_unit(
                      System.monotonic_time() - start,
                      :native,
                      :millisecond
                    )

                  {:ok, resp_packet, duration}

                other ->
                  Logger.warning(
                    "DNS Server: UDP query response from upstream #{inspect(upstream)} failed: #{inspect(other)}"
                  )

                  {:error, {:recv_error, other}}
              end

            other ->
              Logger.warning(
                "DNS Server: UDP send to upstream #{inspect(upstream)} failed: #{inspect(other)}"
              )

              {:error, {:send_error, other}}
          end
        after
          :gen_udp.close(client_sock)
        end

      other ->
        Logger.error(
          "DNS Server: UDP socket creation to query upstream #{inspect(upstream)} failed: #{inspect(other)}"
        )

        {:error, {:socket_error, other}}
    end
  end

  defp query_upstream({:doh, url}, packet) do
    start = System.monotonic_time()

    case Req.post(url,
           headers: [
             {"content-type", "application/dns-message"},
             {"accept", "application/dns-message"}
           ],
           body: packet,
           connect_options: [protocols: [:http2, :http1]],
           retry: false,
           receive_timeout: 3000
         ) do
      {:ok, %{status: 200, body: resp_packet}} ->
        duration =
          System.convert_time_unit(
            System.monotonic_time() - start,
            :native,
            :millisecond
          )

        {:ok, resp_packet, duration}

      other ->
        Logger.warning("DNS Server: DoH query to upstream #{url} failed: #{inspect(other)}")
        {:error, {:doh_error, other}}
    end
  end

  defp wait_for_first_success(_tasks, 0), do: {:error, :all_failed}

  defp wait_for_first_success(tasks, remaining_count) do
    receive do
      {ref, {:ok, resp_packet, upstream, duration}} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        {:ok, resp_packet, upstream, duration}

      {ref, {:error, _reason}} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        wait_for_first_success(tasks, remaining_count - 1)

      {:DOWN, ref, :process, _pid, _reason} when is_reference(ref) ->
        wait_for_first_success(tasks, remaining_count - 1)
    after
      4000 ->
        {:error, :timeout}
    end
  end

  # --- Cache Functions ---

  defp lookup_cache(profile_id, domain, qtype) do
    now = System.monotonic_time(:second)

    case :ets.lookup(:dns_cache, {profile_id, domain, qtype}) do
      [{{^profile_id, ^domain, ^qtype}, resp_packet, expires_at}] ->
        if now < expires_at do
          {:ok, resp_packet}
        else
          :ets.delete(:dns_cache, {profile_id, domain, qtype})
          :error
        end

      _ ->
        :error
    end
  end

  defp store_cache(profile_id, domain, qtype, resp_packet) do
    ttl = Packet.extract_min_ttl(resp_packet)
    expires_at = System.monotonic_time(:second) + ttl
    :ets.insert(:dns_cache, {{profile_id, domain, qtype}, resp_packet, expires_at})
  end

  # --- Rules & Filtering Matching Helpers ---

  defp get_custom_rules(rules) when is_list(rules), do: rules
  defp get_custom_rules(rules) when is_map(rules), do: Map.get(rules, "custom_rules", []) || []
  defp get_custom_rules(_), do: []

  defp match_custom_rules(domain, custom_rules) do
    Enum.find_value(custom_rules, {nil, nil}, fn rule ->
      r_domain = Map.get(rule, "domain") || Map.get(rule, :domain)

      if r_domain && (domain == r_domain or String.ends_with?(domain, "." <> r_domain)) do
        action = Map.get(rule, "action") || Map.get(rule, :action)
        value = Map.get(rule, "value") || Map.get(rule, :value)
        {action, value}
      else
        nil
      end
    end)
  end

  defp match_domain_set?(domain, set) do
    domain == domain &&
      (MapSet.member?(set, domain) or
         Enum.any?(set, fn suffix -> String.ends_with?(domain, "." <> suffix) end))
  end

  # --- Log Parsing & Recording ---

  defp parse_resolved_ip(resp_packet) do
    case Packet.extract_resolved_ips(resp_packet) do
      [] ->
        "Resolved"

      ips ->
        Enum.join(ips, ", ")
    end
  end

  defp log_and_broadcast(
         profile_id,
         client_ip,
         domain,
         qtype,
         status,
         answer,
         duration_ms,
         enable_query_logging
       ) do
    if enable_query_logging do
      pair_id = to_string(profile_id)
      client_name = Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip)

      log_data = %{
        "pair_id" => pair_id,
        "client_ip" => client_ip,
        "client_name" => client_name || client_ip,
        "domain" => domain,
        "type" => Packet.qtype_to_string(qtype),
        "status" => status,
        "answer" => answer,
        "duration" => duration_ms,
        "timestamp" => System.system_time(:second)
      }

      counter = System.unique_integer([:monotonic])
      :ets.insert(@table, {{pair_id, counter}, log_data})
      prune_logs(pair_id)

      Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{profile_id}", {:dns_log, log_data})
    end
  end

  defp prune_logs(pair_id) do
    pattern = {{pair_id, :"$1"}, :_}
    keys = :ets.select(@table, [{pattern, [], [:"$1"]}])

    if length(keys) > 200 do
      to_delete_count = length(keys) - 200

      Enum.take(keys, to_delete_count)
      |> Enum.each(fn counter ->
        :ets.delete(@table, {pair_id, counter})
      end)
    end
  end

  # --- General IP and URL parsing ---

  defp parse_upstreams(upstream_str) do
    upstream_str
    |> String.split([",", " "], trim: true)
    |> Enum.map(fn val ->
      case :inet.parse_address(String.to_charlist(val)) do
        {:ok, addr} ->
          {:udp, addr}

        _ ->
          if String.starts_with?(val, "https://") do
            {:doh, val}
          else
            nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def match_ets_blocklist?(domain, table) do
    domain = String.downcase(domain)

    if :ets.member(table, domain) do
      true
    else
      match_suffix_recursive(domain, table)
    end
  end

  defp match_suffix_recursive(domain, table) do
    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = String.slice(domain, idx + 1, byte_size(domain))

        if :ets.member(table, suffix) do
          true
        else
          match_suffix_recursive(suffix, table)
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

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
