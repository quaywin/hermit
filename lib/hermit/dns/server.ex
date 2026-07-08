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
    config = Hermit.Vpn.DnsConfig.get_for_profile(profile_id)

    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config:#{profile_id}")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{config.id}")
    end

    upstreams = parse_upstreams(config.upstream_dns)
    upstreams_map = Enum.into(upstreams, %{}, fn ip -> {ip, 20} end)

    active_upstream =
      if map_size(upstreams_map) > 0 do
        {best_ip, _best_latency} = Enum.min_by(upstreams_map, fn {_ip, lat} -> lat end)
        best_ip
      else
        nil
      end

    custom_rules = precompile_custom_rules(config.custom_rules)

    # Initialize a shared Req client for DoH queries to reuse TLS connections
    doh_client =
      Req.new(
        connect_options: [protocols: [:http2, :http1]],
        retry: false,
        receive_timeout: 2000
      )

    # Bind the client sockets for sending/receiving upstream queries asynchronously immediately.
    # We open a pool of 4 sockets to prevent Transaction ID collisions under heavy load.
    upstream_sockets =
      Enum.map(1..4, fn _ ->
        case :gen_udp.open(0, [:binary, active: true]) do
          {:ok, sock} -> sock
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> List.to_tuple()

    if tuple_size(upstream_sockets) == 0 do
      Logger.error("DNS Server: Failed to bind any upstream client sockets")
    end

    state = %{
      socket: nil,
      upstream_sockets: upstream_sockets,
      doh_client: doh_client,
      pending_queries: %{},
      port: port,
      profile_id: profile_id,
      upstreams: upstreams,
      upstreams_map: upstreams_map,
      active_upstream: active_upstream,
      config: config,
      custom_rules: custom_rules
    }

    # Start periodic timeout cleanup timer (every 1 second)
    :erlang.send_after(1000, self(), :clean_timeouts)

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
        [:binary, active: 100, reuseaddr: true]
      else
        [:binary, active: 100, reuseaddr: true, ip: {10, 251, profile_id, 1}]
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
  def handle_info({:dns_config_updated, updated_config}, state) do
    upstreams = parse_upstreams(updated_config.upstream_dns)
    new_state = sync_upstreams_config(state, upstreams)
    custom_rules = precompile_custom_rules(updated_config.custom_rules)

    # Flush cache for this profile on configuration changes
    profile_id = state.profile_id

    :ets.select_delete(:dns_cache, [
      {{{profile_id, :_, :_}, :_, :_, :_, :_}, [], [true]},
      {{{profile_id, :_, :_}, :_, :_}, [], [true]}
    ])

    {:noreply, %{new_state | config: updated_config, custom_rules: custom_rules}}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{socket: socket} = state) do
    case Packet.parse(packet) do
      {:ok, query} ->
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

  # Handle asynchronous responses from upstream DNS servers
  @impl true
  def handle_info(
        {:udp, upstream_socket, upstream_ip, upstream_port, packet},
        state
      ) do
    is_our_upstream_socket? =
      is_tuple(state.upstream_sockets) and upstream_socket in Tuple.to_list(state.upstream_sockets)

    if is_our_upstream_socket? and byte_size(packet) >= 12 do
      <<tx_id::16, _::binary>> = packet

      case Map.get(state.pending_queries, tx_id) do
        {client_ip, client_port, original_query, sent_at, target_upstreams, current_index} ->
          upstream = elem(target_upstreams, current_index)
          # Only accept response if it matches the source IP of the current active upstream
          is_valid_source? =
            case upstream do
              {:udp, {^upstream_ip, ^upstream_port}} -> true
              {:udp, ^upstream_ip} when upstream_port == 53 -> true
              _ -> false
            end

          if is_valid_source? do
            client_socket = state.socket
            enable_query_logging = state.config.enable_query_logging
            profile_id = state.profile_id
            config_id = state.config.id
            server_pid = self()

            # Offload heavy tasks to Task.Supervisor
            Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
              # Send response packet back to client immediately
              :gen_udp.send(client_socket, client_ip, client_port, packet)

              # Calculate resolution duration and cast back to server
              duration = System.monotonic_time(:millisecond) - sent_at
              GenServer.cast(server_pid, {:update_latency, upstream, duration})

              # Parse metadata and store cache
              {ttl, answer_log_info} =
                case Packet.parse_response_metadata(packet, enable_query_logging) do
                  {:ok, extracted_ttl, ips} ->
                    if enable_query_logging do
                      answer = if ips == [], do: "Resolved", else: Enum.join(ips, ", ")
                      {extracted_ttl, answer}
                    else
                      {extracted_ttl, "Resolved"}
                    end

                  _ ->
                    {10, "Resolved"}
                end

              store_cache(
                profile_id,
                original_query.domain,
                original_query.qtype,
                packet,
                "resolved",
                answer_log_info,
                ttl
              )

              resolver_tag =
                case upstream do
                  {:udp, {ip_addr, port}} -> "UDP (#{ip_to_string(ip_addr)}:#{port})"
                  {:udp, ip_addr} -> "UDP (#{ip_to_string(ip_addr)})"
                  {:doh, url} -> "DoH (#{extract_host(url)})"
                end

              log_and_broadcast(
                profile_id,
                config_id,
                client_ip,
                original_query.domain,
                original_query.qtype,
                "resolved",
                answer_log_info,
                resolver_tag,
                enable_query_logging
              )
            end)

            # Cleanup pending query immediately in GenServer state
            new_pending = Map.delete(state.pending_queries, tx_id)
            {:noreply, %{state | pending_queries: new_pending}}
          else
            {:noreply, state}
          end

        nil ->
          # Query not found (potentially timed out and cleaned up)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # Handle asynchronous DoH responses from background task
  @impl true
  def handle_info({:doh_response, tx_id, url, packet, duration}, state) do
    case Map.get(state.pending_queries, tx_id) do
      {client_ip, client_port, original_query, _sent_at, target_upstreams, current_index} ->
        upstream = elem(target_upstreams, current_index)

        expected_url =
          case upstream do
            {:doh, u} -> u
            _ -> nil
          end

        if expected_url == url do
          client_socket = state.socket
          enable_query_logging = state.config.enable_query_logging
          profile_id = state.profile_id
          config_id = state.config.id
          server_pid = self()

          # Offload heavy tasks to Task.Supervisor
          Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
            # Send response packet back to client
            :gen_udp.send(client_socket, client_ip, client_port, packet)

            # Log latency update
            GenServer.cast(server_pid, {:update_latency, upstream, duration})

            # Parse metadata and store cache
            {ttl, answer_log_info} =
              case Packet.parse_response_metadata(packet, enable_query_logging) do
                {:ok, extracted_ttl, ips} ->
                  if enable_query_logging do
                    answer = if ips == [], do: "Resolved", else: Enum.join(ips, ", ")
                    {extracted_ttl, answer}
                  else
                    {extracted_ttl, "Resolved"}
                  end

                _ ->
                  {10, "Resolved"}
              end

            store_cache(
              profile_id,
              original_query.domain,
              original_query.qtype,
              packet,
              "resolved",
              answer_log_info,
              ttl
            )

            resolver_tag = "DoH (#{extract_host(url)})"

            log_and_broadcast(
              profile_id,
              config_id,
              client_ip,
              original_query.domain,
              original_query.qtype,
              "resolved",
              answer_log_info,
              resolver_tag,
              enable_query_logging
            )
          end)

          # Cleanup pending query
          new_pending = Map.delete(state.pending_queries, tx_id)
          {:noreply, %{state | pending_queries: new_pending}}
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  # Handle periodic lazy timeout cleanups & fallback triggering (every 1s)
  @impl true
  def handle_info(:clean_timeouts, state) do
    now = System.monotonic_time(:millisecond)

    new_state =
      Enum.reduce(state.pending_queries, state, fn {tx_id, info}, acc_state ->
        {_client_ip, _client_port, _original_query, sent_at, _target_upstreams, _current_index} = info

        # Nếu bị quá hạn 2 giây mà chưa nhận được phản hồi
        if now - sent_at >= 2000 do
          handle_upstream_failure(tx_id, acc_state)
        else
          acc_state
        end
      end)

    :erlang.send_after(1000, self(), :clean_timeouts)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:doh_failure, tx_id, _url}, state) do
    # Kích hoạt failover lập tức khi nhận tin báo lỗi từ Task DoH
    new_state = handle_upstream_failure(tx_id, state)
    {:noreply, new_state}
  end

  # Hàm helper dùng chung xử lý lỗi upstream được chuyển xuống dưới
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
  def handle_info({:udp_passive, socket}, %{socket: socket} = state) do
    :inet.setopts(socket, active: 100)
    {:noreply, state}
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

      %{
        state
        | upstreams: upstreams,
          upstreams_map: upstreams_map,
          active_upstream: active_upstream
      }
    end
  end

  defp process_query_fast_path(socket, ip, port, packet, query, state) do
    profile_id = state.profile_id
    config = state.config
    upstreams = state.upstreams
    enable_query_logging = config.enable_query_logging

    # 0. AAAA Blocking (Filter IPv6)
    if query.qtype == :AAAA and Map.get(config, :block_ipv6, false) do
      resp = Packet.build_empty_response(query.id, query.query_record)
      :gen_udp.send(socket, ip, port, resp)

      log_and_broadcast(
        profile_id,
        config.id,
        ip,
        query.domain,
        query.qtype,
        "blocked",
        "Empty (IPv6 Blocked)",
        "Local Filter",
        enable_query_logging
      )

      state
    else
      # 1. Lookup cache first (max optimization)
      case lookup_cache(profile_id, query.domain, query.qtype) do
        {:ok, cached_packet, status, answer_log_info} ->
        <<_old_id::binary-size(2), rest_packet::binary>> = cached_packet
        resp_packet = query.id <> rest_packet
        :gen_udp.send(socket, ip, port, resp_packet)

        cached_answer =
          if status == "resolved" do
            "#{answer_log_info} (cached)"
          else
            answer_log_info
          end

        log_and_broadcast(
          profile_id,
          config.id,
          ip,
          query.domain,
          query.qtype,
          status,
          cached_answer,
          "Cache",
          enable_query_logging
        )

        state

      :error ->
        # 2. Match custom rules
        {action, redirect_val} = match_custom_rules(query.domain, state.custom_rules)

        # 3. Match built-in blocklists if not matched by custom rules
        {action, redirect_val} =
          if is_nil(action) and config.enabled do
            cond do
              config.block_ads and match_ets_blocklist?(query.domain, :adguard_blocklist) ->
                {"block", nil}

              config.block_goodbyeads and
                  match_ets_blocklist?(query.domain, :goodbyeads_blocklist) ->
                {"block", nil}

              config.block_adult and match_domain_set?(query.domain, @adult_domains) ->
                {"block", nil}

              true ->
                {nil, nil}
            end
          else
            {action, redirect_val}
          end

        case action do
          "block" ->
            resp = Packet.build_nxdomain(query.id, query.query_record)
            # Store blocks in cache with 5s TTL
            store_cache(profile_id, query.domain, query.qtype, resp, "blocked", "NXDOMAIN", 5)
            :gen_udp.send(socket, ip, port, resp)

            log_and_broadcast(
              profile_id,
              config.id,
              ip,
              query.domain,
              query.qtype,
              "blocked",
              "NXDOMAIN",
              "Local Filter",
              enable_query_logging
            )

            state

          "redirect" when not is_nil(redirect_val) ->
            if query.qtype == :A do
              resp = Packet.build_a_response(query.id, query.query_record, redirect_val)
              # Store redirects in cache with 5s TTL
              store_cache(
                profile_id,
                query.domain,
                query.qtype,
                resp,
                "redirected",
                redirect_val,
                5
              )

              :gen_udp.send(socket, ip, port, resp)

              log_and_broadcast(
                profile_id,
                config.id,
                ip,
                query.domain,
                query.qtype,
                "redirected",
                redirect_val,
                "Local Rules",
                enable_query_logging
              )
            else
              resp = Packet.build_nxdomain(query.id, query.query_record)
              # Store redirect failures in cache with 5s TTL
              store_cache(
                profile_id,
                query.domain,
                query.qtype,
                resp,
                "redirected",
                "NXDOMAIN",
                5
              )

              :gen_udp.send(socket, ip, port, resp)

              log_and_broadcast(
                profile_id,
                config.id,
                ip,
                query.domain,
                query.qtype,
                "redirected",
                "NXDOMAIN",
                "Local Rules",
                enable_query_logging
              )
            end

            state

          _ ->
            # Split routing based on domain
            target_upstreams = select_upstreams_for_domain(query.domain, upstreams)
            async_forward_to_upstream(socket, ip, port, packet, query, target_upstreams, state)
        end
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

  defp async_forward_to_upstream(socket, ip, port, packet, query, target_upstreams, state) do
    # Sort target upstreams based on configured priority and health status
    sorted_upstreams = sort_upstreams_by_priority(target_upstreams, state.upstreams, state.upstreams_map)

    if sorted_upstreams == [] do
      # Return SERVFAIL if no upstreams configured
      servfail = Packet.build_nxdomain(query.id, query.query_record)
      servfail = Packet.patch_rcode(servfail, 2)
      :gen_udp.send(socket, ip, port, servfail)
      state
    else
      # Extract 16-bit transaction ID
      <<tx_id::16>> = query.id
      now = System.monotonic_time(:millisecond)

      # Send asynchronously to the first upstream in the sorted list (index 0)
      first_upstream = hd(sorted_upstreams)
      async_send_to_upstream(state.upstream_sockets, state.doh_client, first_upstream, packet)

      # Save query context in pending_queries map
      # Struct: {client_ip, client_port, original_query, sent_at, target_upstreams_tuple, current_index}
      upstreams_tuple = List.to_tuple(sorted_upstreams)
      query_info = {ip, port, query, now, upstreams_tuple, 0}
      new_pending = Map.put(state.pending_queries, tx_id, query_info)

      %{state | pending_queries: new_pending}
    end
  end

  defp sort_upstreams_by_priority(target_upstreams, upstreams_order, upstreams_map) do
    # Classify upstreams into healthy and penalized (latency >= 2000ms due to timeout)
    {healthy, penalized} =
      Enum.split_with(target_upstreams, fn upstream ->
        latency = Map.get(upstreams_map, upstream, 20)
        latency < 2000
      end)

    # Sort healthy ones based on the original user configuration order
    sorted_healthy =
      Enum.sort_by(healthy, fn upstream ->
        Enum.find_index(upstreams_order, &(&1 == upstream)) || 999
      end)

    # Sort penalized ones similarly
    sorted_penalized =
      Enum.sort_by(penalized, fn upstream ->
        Enum.find_index(upstreams_order, &(&1 == upstream)) || 999
      end)

    # Healthy ones first, penalized ones last (Failover)
    sorted_healthy ++ sorted_penalized
  end

  defp async_send_to_upstream(upstream_sockets, _doh_client, {:udp, {ip, port}}, packet) when is_tuple(upstream_sockets) do
    # For UDP upstreams with specific port, send immediately using a socket from the pool
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, port, packet)
  end

  defp async_send_to_upstream(upstream_sockets, _doh_client, {:udp, ip}, packet)
       when is_tuple(upstream_sockets) and is_tuple(ip) do
    # For UDP upstreams with only IP, default port to 53
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, 53, packet)
  end

  defp async_send_to_upstream(_upstream_sockets, doh_client, {:doh, url}, packet) do
    # For DoH upstreams, send asynchronously using a Task
    # Since HTTP Req calls are blocking, we task them to avoid blocking the GenServer
    server_pid = self()
    <<tx_id::16, _::binary>> = packet

    Task.start(fn ->
      start = System.monotonic_time()

      case Req.post(doh_client,
             url: url,
             headers: [
               {"content-type", "application/dns-message"},
               {"accept", "application/dns-message"}
             ],
             body: packet
           ) do
        {:ok, %{status: 200, body: resp_packet}} ->
          # Fetch original transaction ID from query to rewrite in case Upstream changed it
          <<upstream_tx_id::16, _::binary>> = resp_packet

          final_packet =
            if upstream_tx_id != tx_id do
              <<_::16, rest::binary>> = resp_packet
              <<tx_id::16, rest::binary>>
            else
              resp_packet
            end

          duration =
            System.convert_time_unit(
              System.monotonic_time() - start,
              :native,
              :millisecond
            )

          # Send fake UDP packet back to server loop to handle response unified
          # This allows the GenServer to handle DoH responses exactly like UDP responses
          # IP 127.0.0.1 is used as indicator that this is a DoH response from this task
          send(server_pid, {:doh_response, tx_id, url, final_packet, duration})

        other ->
          Logger.warning("DNS Server: DoH query to upstream #{url} failed: #{inspect(other)}")
          send(server_pid, {:doh_failure, tx_id, url})
      end
    end)
  end

  # Hàm helper dùng chung xử lý lỗi upstream
  defp handle_upstream_failure(tx_id, state) do
    case Map.get(state.pending_queries, tx_id) do
      {client_ip, client_port, original_query, _sent_at, target_upstreams, current_index} ->
        failed_upstream = elem(target_upstreams, current_index)

        # 1. Phạt độ trễ ngay lập tức trong state của GenServer
        new_upstreams_map = Map.put(state.upstreams_map, failed_upstream, 2000)
        active_upstream =
          if map_size(new_upstreams_map) > 0 do
            {best_ip, _best_latency} = Enum.min_by(new_upstreams_map, fn {_ip, lat} -> lat end)
            best_ip
          else
            nil
          end

        state = %{state | upstreams_map: new_upstreams_map, active_upstream: active_upstream}
        next_index = current_index + 1

        if next_index < tuple_size(target_upstreams) do
          # 2. Có DNS dự phòng: Gửi truy vấn qua DNS tiếp theo ngay lập tức
          next_upstream = elem(target_upstreams, next_index)
          packet = Packet.build_query_packet(tx_id, original_query.query_record)
          async_send_to_upstream(state.upstream_sockets, state.doh_client, next_upstream, packet)

          # Cập nhật thông tin truy vấn trong pending_queries
          now = System.monotonic_time(:millisecond)
          updated_info = {client_ip, client_port, original_query, now, target_upstreams, next_index}
          new_pending = Map.put(state.pending_queries, tx_id, updated_info)

          %{state | pending_queries: new_pending}
        else
          # 3. Hết DNS dự phòng: Trả về SERVFAIL cho client
          servfail = Packet.build_nxdomain(original_query.id, original_query.query_record)
          servfail = Packet.patch_rcode(servfail, 2)
          :gen_udp.send(state.socket, client_ip, client_port, servfail)

          # Lưu cache lỗi SERVFAIL trong 5 giây (Negative Caching)
          store_cache(
            state.profile_id,
            original_query.domain,
            original_query.qtype,
            servfail,
            "resolved",
            "SERVFAIL",
            5
          )

          log_and_broadcast(
            state.profile_id,
            state.config.id,
            client_ip,
            original_query.domain,
            original_query.qtype,
            "resolved",
            "SERVFAIL",
            "Failover",
            state.config.enable_query_logging
          )

          new_pending = Map.delete(state.pending_queries, tx_id)
          %{state | pending_queries: new_pending}
        end

      nil ->
        state
    end
  end

  # Simplified query_upstream for active latency probing task
  defp query_upstream({:udp, upstream}, packet) do
    start = System.monotonic_time()

    {ip, port} =
      case upstream do
        {ip_addr, p} -> {ip_addr, p}
        ip_addr when is_tuple(ip_addr) -> {ip_addr, 53}
      end

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        try do
          case :gen_udp.send(socket, ip, port, packet) do
            :ok ->
              case :gen_udp.recv(socket, 0, 1500) do
                {:ok, {_ip, _port, resp_packet}} ->
                  duration =
                    System.convert_time_unit(
                      System.monotonic_time() - start,
                      :native,
                      :millisecond
                    )

                  {:ok, resp_packet, duration}

                other ->
                  {:error, other}
              end

            other ->
              {:error, other}
          end
        after
          :gen_udp.close(socket)
        end

      other ->
        {:error, other}
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
           retry: false,
           receive_timeout: 1500
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
        {:error, other}
    end
  end

  # --- Cache Functions ---

  defp lookup_cache(profile_id, domain, qtype) do
    now = System.monotonic_time(:second)

    case :ets.lookup(:dns_cache, {profile_id, domain, qtype}) do
      [{{^profile_id, ^domain, ^qtype}, resp_packet, status, answer_log_info, expires_at}] ->
        if now < expires_at do
          {:ok, resp_packet, status, answer_log_info}
        else
          :ets.delete(:dns_cache, {profile_id, domain, qtype})
          :error
        end

      _ ->
        :error
    end
  end

  defp store_cache(profile_id, domain, qtype, resp_packet, status, answer_log_info, ttl) do
    expires_at = System.monotonic_time(:second) + ttl

    :ets.insert(
      :dns_cache,
      {{profile_id, domain, qtype}, resp_packet, status, answer_log_info, expires_at}
    )
  end

  # --- Rules & Filtering Matching Helpers ---

  defp match_custom_rules(_domain, rules_map) when map_size(rules_map) == 0, do: {nil, nil}

  defp match_custom_rules(domain, rules_map) do
    case Map.get(rules_map, domain) do
      {_action, _value} = result ->
        result

      nil ->
        case :binary.match(domain, ".") do
          {idx, _} ->
            parent = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
            match_custom_rules(parent, rules_map)

          :nomatch ->
            {nil, nil}
        end
    end
  end

  defp precompile_custom_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(fn rule ->
      domain = Map.get(rule, "domain") || Map.get(rule, :domain)
      action = Map.get(rule, "action") || Map.get(rule, :action)
      value = Map.get(rule, "value") || Map.get(rule, :value)
      {domain, {action, value}}
    end)
    |> Enum.reject(fn {domain, _} -> is_nil(domain) end)
    |> Map.new()
  end

  defp precompile_custom_rules(rules) when is_map(rules) do
    precompile_custom_rules(Map.get(rules, "custom_rules", []) || [])
  end

  defp precompile_custom_rules(_), do: %{}

  defp match_domain_set?(domain, set) do
    domain = String.downcase(domain)
    MapSet.member?(set, domain) or match_domain_set_recursive?(domain, set)
  end

  defp match_domain_set_recursive?(domain, set) do
    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        if MapSet.member?(set, suffix) do
          true
        else
          match_domain_set_recursive?(suffix, set)
        end
    end
  end

  # --- Log Recording ---

  defp extract_host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when not is_nil(host) -> host
      _ -> "DoH Server"
    end
  end

  defp log_and_broadcast(profile_id, config_id, client_ip, domain, qtype, status, answer, resolver, true) do
    Task.start(fn ->
      pair_id = to_string(profile_id)
      client_ip_str = ip_to_string(client_ip)
      client_name = Hermit.Vpn.DnsDeviceResolver.resolve_device(profile_id, client_ip_str)

      log_data = %{
        "pair_id" => pair_id,
        "client_ip" => client_ip_str,
        "client_name" => client_name || client_ip_str,
        "domain" => domain,
        "type" => Packet.qtype_to_string(qtype),
        "status" => status,
        "answer" => answer,
        "resolver" => resolver,
        "timestamp" => System.system_time(:second)
      }

      counter = System.unique_integer([:monotonic])
      :ets.insert(@table, {{pair_id, counter}, log_data})
      # Đồng bộ lưu thêm vào ETS theo dns_profile_id để phục vụ trang /dns load logs cũ
      :ets.insert(:dns_query_logs, {{config_id, counter}, log_data})

      # Broadcast tới cả kênh inbound cũ và kênh dns profile mới
      Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{profile_id}", {:dns_log, log_data})
      Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs_profile:#{config_id}", {:dns_log, log_data})
    end)
    :ok
  end

  defp log_and_broadcast(
         _profile_id,
         _config_id,
         _client_ip,
         _domain,
         _qtype,
         _status,
         _answer_or_packet,
         _resolver,
         false
       ) do
    :ok
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
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

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
