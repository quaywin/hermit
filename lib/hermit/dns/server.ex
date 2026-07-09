defmodule Hermit.Dns.Server do
  use GenServer
  require Logger
  alias Hermit.Dns.Packet
  alias Hermit.Dns.Rules
  alias Hermit.Dns.Filter
  alias Hermit.Dns.Cache


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

    custom_rules = Rules.precompile(config.custom_rules)

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
        case :gen_udp.open(0, [:binary, active: true, recbuf: 1024 * 1024, read_packets: 1000]) do
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
      custom_rules: custom_rules,
      next_tx_id: 0
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
        [:binary, active: 100, reuseaddr: true, recbuf: 1024 * 1024, read_packets: 1000]
      else
        [:binary, active: 100, reuseaddr: true, ip: {10, 251, profile_id, 1}, recbuf: 1024 * 1024, read_packets: 1000]
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
  def handle_call({:resolve_query, packet, client_ip}, from, state) do
    case Packet.parse(packet) do
      {:ok, query} ->
        new_state = process_query_fast_path(nil, client_ip, from, packet, query, state)
        {:noreply, new_state}

      {:error, _reason} ->
        if byte_size(packet) >= 12 do
          <<id::binary-size(2), _::binary>> = packet
          err_resp = <<id::binary, 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
          {:reply, {:ok, err_resp}, state}
        else
          {:reply, {:error, :bad_packet}, state}
        end
    end
  end

  @impl true
  def handle_info({:dns_config_updated, updated_config}, state) do
    upstreams = parse_upstreams(updated_config.upstream_dns)
    new_state = sync_upstreams_config(state, upstreams)
    custom_rules = Rules.precompile(updated_config.custom_rules)

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
        {client_ip, client_port, original_query, sent_at, target_upstreams, current_index, original_tx_id} ->
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
              # Sửa ID của gói tin phản hồi thành ID gốc từ client trước khi gửi đi
              <<_::binary-size(2), rest_packet::binary>> = packet
              client_packet = original_tx_id <> rest_packet

              # Send response packet back to client immediately
              send_client_response(client_socket, client_ip, client_port, client_packet)

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

              Cache.store(
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

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: duration},
                %{
                  profile_id: profile_id,
                  config_id: config_id,
                  client_ip: client_ip,
                  domain: original_query.domain,
                  qtype: original_query.qtype,
                  status: "resolved",
                  answer: answer_log_info,
                  resolver: resolver_tag,
                  enable_query_logging: enable_query_logging
                }
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
      {client_ip, client_port, original_query, _sent_at, target_upstreams, current_index, original_tx_id} ->
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
            # Sửa ID của gói tin phản hồi thành ID gốc từ client trước khi gửi đi
            <<_::binary-size(2), rest_packet::binary>> = packet
            client_packet = original_tx_id <> rest_packet

            # Send response packet back to client
            send_client_response(client_socket, client_ip, client_port, client_packet)

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

            Cache.store(
              profile_id,
              original_query.domain,
              original_query.qtype,
              packet,
              "resolved",
              answer_log_info,
              ttl
            )

            resolver_tag = "DoH (#{extract_host(url)})"

            :telemetry.execute(
              [:hermit, :dns, :query],
              %{duration: duration},
              %{
                profile_id: profile_id,
                config_id: config_id,
                client_ip: client_ip,
                domain: original_query.domain,
                qtype: original_query.qtype,
                status: "resolved",
                answer: answer_log_info,
                resolver: resolver_tag,
                enable_query_logging: enable_query_logging
              }
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
        {_client_ip, _client_port, _original_query, sent_at, _target_upstreams, _current_index, _original_tx_id} = info

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
      send_client_response(socket, ip, port, resp)

      :telemetry.execute(
        [:hermit, :dns, :query],
        %{duration: 0},
        %{
          profile_id: profile_id,
          config_id: config.id,
          client_ip: ip,
          domain: query.domain,
          qtype: query.qtype,
          status: "blocked",
          answer: "Empty (IPv6 Blocked)",
          resolver: "Local Filter",
          block_reason: "ipv6",
          enable_query_logging: enable_query_logging
        }
      )

      state
    else
      # 1. Lookup cache first (max optimization)
      case Cache.lookup(profile_id, query.domain, query.qtype) do
        {:ok, cached_packet, status, answer_log_info} ->
        <<_old_id::binary-size(2), rest_packet::binary>> = cached_packet
        resp_packet = query.id <> rest_packet
        send_client_response(socket, ip, port, resp_packet)

        cached_answer =
          if status == "resolved" do
            "#{answer_log_info} (cached)"
          else
            answer_log_info
          end

        block_reason =
          if status == "blocked" do
            cond do
              String.contains?(answer_log_info, "IPv6") -> "ipv6"
              String.contains?(answer_log_info, "AdGuard") -> "adguard"
              String.contains?(answer_log_info, "GoodbyeAds") -> "goodbyeads"
              String.contains?(answer_log_info, "Adult") -> "adult"
              String.contains?(answer_log_info, "Custom") -> "custom_rule"
              true -> nil
            end
          else
            nil
          end

        :telemetry.execute(
          [:hermit, :dns, :query],
          %{duration: 0},
          %{
            profile_id: profile_id,
            config_id: config.id,
            client_ip: ip,
            domain: query.domain,
            qtype: query.qtype,
            status: status,
            answer: cached_answer,
            resolver: "Cache",
            block_reason: block_reason,
            enable_query_logging: enable_query_logging
          }
        )

        state

      :error ->
        # 2. Match custom rules
        {action, redirect_val, block_reason} =
          case Rules.match(query.domain, state.custom_rules) do
            {"block", nil} -> {"block", nil, "custom_rule"}
            {act, val} -> {act, val, nil}
          end

        # 3. Match built-in blocklists if not matched by custom rules
        {action, redirect_val, block_reason} =
          if is_nil(action) and config.enabled do
            cond do
              config.block_ads and Filter.match_ets_blocklist?(query.domain, :adguard_blocklist) ->
                {"block", nil, "adguard"}

              config.block_goodbyeads and
                  Filter.match_ets_blocklist?(query.domain, :goodbyeads_blocklist) ->
                {"block", nil, "goodbyeads"}

              config.block_adult and Filter.match_adult?(query.domain) ->
                {"block", nil, "adult"}

              true ->
                {nil, nil, nil}
            end
          else
            {action, redirect_val, block_reason}
          end

        case action do
          "block" ->
            resp = Packet.build_nxdomain(query.id, query.query_record)

            answer_log_info =
              case block_reason do
                "adguard" -> "NXDOMAIN (AdGuard)"
                "goodbyeads" -> "NXDOMAIN (GoodbyeAds)"
                "adult" -> "NXDOMAIN (Adult Filter)"
                "custom_rule" -> "NXDOMAIN (Custom Rule)"
                _ -> "NXDOMAIN"
              end

            # Store blocks in cache with 5s TTL
            Cache.store(profile_id, query.domain, query.qtype, resp, "blocked", answer_log_info, 5)
            send_client_response(socket, ip, port, resp)

            :telemetry.execute(
              [:hermit, :dns, :query],
              %{duration: 0},
              %{
                profile_id: profile_id,
                config_id: config.id,
                client_ip: ip,
                domain: query.domain,
                qtype: query.qtype,
                status: "blocked",
                answer: answer_log_info,
                resolver: "Local Filter",
                block_reason: block_reason,
                enable_query_logging: enable_query_logging
              }
            )

            state

          "redirect" when not is_nil(redirect_val) ->
            if query.qtype == :A do
              resp = Packet.build_a_response(query.id, query.query_record, redirect_val)
              # Store redirects in cache with 5s TTL
              Cache.store(
                profile_id,
                query.domain,
                query.qtype,
                resp,
                "redirected",
                redirect_val,
                5
              )

              send_client_response(socket, ip, port, resp)

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: 0},
                %{
                  profile_id: profile_id,
                  config_id: config.id,
                  client_ip: ip,
                  domain: query.domain,
                  qtype: query.qtype,
                  status: "redirected",
                  answer: redirect_val,
                  resolver: "Local Rules",
                  enable_query_logging: enable_query_logging
                }
              )
            else
              resp = Packet.build_nxdomain(query.id, query.query_record)
              # Store redirect failures in cache with 5s TTL
              Cache.store(
                profile_id,
                query.domain,
                query.qtype,
                resp,
                "redirected",
                "NXDOMAIN",
                5
              )

              send_client_response(socket, ip, port, resp)

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: 0},
                %{
                  profile_id: profile_id,
                  config_id: config.id,
                  client_ip: ip,
                  domain: query.domain,
                  qtype: query.qtype,
                  status: "redirected",
                  answer: "NXDOMAIN",
                  resolver: "Local Rules",
                  enable_query_logging: enable_query_logging
                }
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
      send_client_response(socket, ip, port, servfail)
      state
    else
      # Sinh unique upstream transaction ID mới
      upstream_tx_id = state.next_tx_id
      next_tx_id = rem(upstream_tx_id + 1, 65536)
      upstream_tx_id_bin = <<upstream_tx_id::16>>

      # Rewrite Transaction ID trong gói tin gửi đi
      <<_old_id::binary-size(2), rest_packet::binary>> = packet
      rewritten_packet = upstream_tx_id_bin <> rest_packet

      now = System.monotonic_time(:millisecond)

      # Send asynchronously to the first upstream in the sorted list (index 0)
      first_upstream = hd(sorted_upstreams)
      async_send_to_upstream(state.upstream_sockets, state.doh_client, first_upstream, rewritten_packet)

      # Save query context in pending_queries map
      # Struct: {client_ip, client_port, original_query, sent_at, target_upstreams_tuple, current_index, original_tx_id}
      upstreams_tuple = List.to_tuple(sorted_upstreams)
      query_info = {ip, port, query, now, upstreams_tuple, 0, query.id}
      new_pending = Map.put(state.pending_queries, upstream_tx_id, query_info)

      %{state | pending_queries: new_pending, next_tx_id: next_tx_id}
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
      {client_ip, client_port, original_query, sent_at, target_upstreams, current_index, original_tx_id} ->
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
          # Gửi với tx_id (ID mới dùng cho upstream)
          packet = Packet.build_query_packet(tx_id, original_query.query_record)
          async_send_to_upstream(state.upstream_sockets, state.doh_client, next_upstream, packet)

          # Cập nhật thông tin truy vấn trong pending_queries
          now = System.monotonic_time(:millisecond)
          updated_info = {client_ip, client_port, original_query, now, target_upstreams, next_index, original_tx_id}
          new_pending = Map.put(state.pending_queries, tx_id, updated_info)

          %{state | pending_queries: new_pending}
        else
          # 3. Hết DNS dự phòng: Thử tìm trong cache stale trước khi trả SERVFAIL! (Serve-Stale - RFC 8767)
          case Cache.lookup(state.profile_id, original_query.domain, original_query.qtype, true) do
            {:stale, stale_packet, status, answer_log_info} ->
              # Sửa ID của stale packet thành ID gốc của client và gửi đi
              <<_::binary-size(2), rest_packet::binary>> = stale_packet
              client_packet = original_tx_id <> rest_packet
              send_client_response(state.socket, client_ip, client_port, client_packet)

              # Bắn telemetry event cho stale response
              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: System.monotonic_time(:millisecond) - sent_at},
                %{
                  profile_id: state.profile_id,
                  config_id: state.config.id,
                  client_ip: client_ip,
                  domain: original_query.domain,
                  qtype: original_query.qtype,
                  status: status,
                  answer: "#{answer_log_info} (stale)",
                  resolver: "Stale Cache Fallback",
                  enable_query_logging: state.config.enable_query_logging
                }
              )

            _ ->
              # Nếu thực sự không có stale cache, trả SERVFAIL như cũ
              servfail = Packet.build_nxdomain(original_tx_id, original_query.query_record)
              servfail = Packet.patch_rcode(servfail, 2)
              send_client_response(state.socket, client_ip, client_port, servfail)

              # Lưu cache lỗi SERVFAIL trong 5 giây (Negative Caching)
              Cache.store(
                state.profile_id,
                original_query.domain,
                original_query.qtype,
                servfail,
                "resolved",
                "SERVFAIL",
                5
              )

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: System.monotonic_time(:millisecond) - sent_at},
                %{
                  profile_id: state.profile_id,
                  config_id: state.config.id,
                  client_ip: client_ip,
                  domain: original_query.domain,
                  qtype: original_query.qtype,
                  status: "resolved",
                  answer: "SERVFAIL",
                  resolver: "Failover Failure",
                  enable_query_logging: state.config.enable_query_logging
                }
              )
          end

          new_pending = Map.delete(state.pending_queries, tx_id)
          %{state | pending_queries: new_pending}
        end

      nil ->
        state
    end
  end

  defp send_client_response(socket, ip, port, resp) do
    if is_tuple(port) do
      GenServer.reply(port, {:ok, resp})
    else
      :gen_udp.send(socket, ip, port, resp)
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





  # --- Log Recording ---

  defp extract_host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when not is_nil(host) -> host
      _ -> "DoH Server"
    end
  end

  # --- General IP and URL parsing ---

  defp parse_upstreams(upstream_str) do
    upstream_str
    |> String.split([",", " "], trim: true)
    |> Enum.map(fn val ->
      cond do
        String.starts_with?(val, "https://") ->
          {:doh, val}

        true ->
          case parse_ip_and_port(val) do
            {:ok, ip, port} -> {:udp, {ip, port}}
            {:ok, ip} -> {:udp, ip}
            :error -> nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_ip_and_port(val) do
    case Regex.run(~r/^\[(.*)\]:(\d+)$/, val) do
      [_, ip_str, port_str] ->
        with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
             {port, ""} <- Integer.parse(port_str) do
          {:ok, ip, port}
        else
          _ -> :error
        end

      nil ->
        case String.split(val, ":") do
          [ip_str, port_str] ->
            with {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_str)),
                 {port, ""} <- Integer.parse(port_str) do
              {:ok, ip, port}
            else
              _ -> :error
            end

          _ ->
            case :inet.parse_address(String.to_charlist(val)) do
              {:ok, ip} -> {:ok, ip}
              _ -> :error
            end
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
