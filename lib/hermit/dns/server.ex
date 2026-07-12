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

    # Flush cache on startup to ensure we start with a clean slate
    Cache.clear(profile_id)

    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config:#{profile_id}")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_config_profile:#{config.id}")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_blocklist")
      Phoenix.PubSub.subscribe(Hermit.PubSub, "vpn_pairs")
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

    proxy_ports_cache = pre_populate_proxy_ports_cache()

    # Create dynamic ETS table for pending_queries to allow concurrent read/write
    pending_table = :"dns_pending_queries_#{profile_id}"

    :ets.new(pending_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    state = %{
      socket: nil,
      tcp_socket: nil,
      upstream_sockets: upstream_sockets,
      doh_client: doh_client,
      pending_table: pending_table,
      server_pid: self(),
      port: port,
      profile_id: profile_id,
      upstreams: upstreams,
      upstreams_map: upstreams_map,
      active_upstream: active_upstream,
      config: config,
      custom_rules: custom_rules,
      next_tx_id: 0,
      proxy_ports_cache: proxy_ports_cache
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
    udp_opts =
      if mock?() do
        [:binary, active: 100, reuseaddr: true, recbuf: 1024 * 1024, read_packets: 1000]
      else
        [
          :binary,
          active: 100,
          reuseaddr: true,
          ip: {10, 251, profile_id, 1},
          recbuf: 1024 * 1024,
          read_packets: 1000
        ]
      end

    tcp_opts =
      if mock?() do
        [:binary, packet: 2, active: false, reuseaddr: true]
      else
        [:binary, packet: 2, active: false, reuseaddr: true, ip: {10, 251, profile_id, 1}]
      end

    case :gen_udp.open(port, udp_opts) do
      {:ok, udp_socket} ->
        case :gen_tcp.listen(port, tcp_opts) do
          {:ok, tcp_socket} ->
            Logger.info(
              "Elixir DNS Server for profile #{profile_id} listening on UDP and TCP port #{port}"
            )

            server_pid = self()
            spawn_link(fn -> tcp_accept_loop(tcp_socket, profile_id, server_pid) end)
            # Start periodic active probing timer
            :erlang.send_after(30_000, self(), :active_probe)
            {:ok, %{state | socket: udp_socket, tcp_socket: tcp_socket}}

          {:error, reason} ->
            :gen_udp.close(udp_socket)

            Logger.warning(
              "Failed to start Elixir DNS TCP Server for profile #{profile_id} on port #{port}: #{inspect(reason)}. Will retry..."
            )

            {:error, reason, state}
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to start Elixir DNS UDP Server for profile #{profile_id} on port #{port}: #{inspect(reason)}. Will retry..."
        )

        {:error, reason, state}
    end
  end

  defp tcp_accept_loop(listen_socket, profile_id, server_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        spawn(fn -> tcp_handle_connection(client_socket, profile_id, server_pid) end)
        tcp_accept_loop(listen_socket, profile_id, server_pid)

      {:error, _reason} ->
        :ok
    end
  end

  defp tcp_handle_connection(client_socket, profile_id, server_pid) do
    case :gen_tcp.recv(client_socket, 0, 5000) do
      {:ok, query_packet} ->
        case :inet.peername(client_socket) do
          {:ok, {ip, _port}} ->
            case GenServer.call(server_pid, {:resolve_query, query_packet, ip}, 5000) do
              {:ok, response_packet} ->
                case :gen_tcp.send(client_socket, response_packet) do
                  :ok -> tcp_handle_connection(client_socket, profile_id, server_pid)
                  _ -> :gen_tcp.close(client_socket)
                end

              _ ->
                :gen_tcp.close(client_socket)
            end

          _ ->
            :gen_tcp.close(client_socket)
        end

      _ ->
        :gen_tcp.close(client_socket)
    end
  end

  @impl true
  def handle_call({:resolve_query, packet, client_ip}, from, state) do
    # Offload TCP query processing to Task.Supervisor to keep GenServer single-thread free
    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
      case Packet.parse(packet) do
        {:ok, query} ->
          process_query_fast_path(nil, client_ip, from, packet, query, state)

        {:error, _reason} ->
          if byte_size(packet) >= 12 do
            <<id::binary-size(2), _::binary>> = packet
            err_resp = <<id::binary, 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
            GenServer.reply(from, {:ok, err_resp})
          else
            GenServer.reply(from, {:error, :bad_packet})
          end
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:dns_config_updated, updated_config}, state) do
    updated_config = Hermit.Repo.preload(updated_config, :blocklists)
    upstreams = parse_upstreams(updated_config.upstream_dns)
    new_state = sync_upstreams_config(state, upstreams)
    custom_rules = Rules.precompile(updated_config.custom_rules)

    # Flush cache for this profile on configuration changes
    Cache.clear(state.profile_id)
    Hermit.Dns.BlocklistLoader.clear_filter_cache()

    {:noreply, %{new_state | config: updated_config, custom_rules: custom_rules}}
  end

  @impl true
  def handle_info({:blocklist_updated, blocklist_id}, state) do
    blocklists =
      case state.config.blocklists do
        %Ecto.Association.NotLoaded{} -> []
        nil -> []
        list -> list
      end

    has_blocklist? = Enum.any?(blocklists, fn b -> b.id == blocklist_id end)

    if has_blocklist? do
      Logger.info(
        "DNS Server (profile #{state.profile_id}): Blocklist #{blocklist_id} updated. Clearing cache."
      )

      Cache.clear(state.profile_id)
      Hermit.Dns.BlocklistLoader.clear_filter_cache()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:vpn_pair_updated, %{id: pair_id, status: status}}, state) do
    status_str = to_string(status) |> String.downcase()

    new_cache =
      if status_str == "running" do
        case read_proxy_ports_from_disk(pair_id) do
          {:ok, http_port, socks5_port} ->
            Map.put(state.proxy_ports_cache, pair_id, {http_port, socks5_port})

          _ ->
            state.proxy_ports_cache
        end
      else
        Map.delete(state.proxy_ports_cache, pair_id)
      end

    {:noreply, %{state | proxy_ports_cache: new_cache}}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, pair_id}, state) do
    new_cache = Map.delete(state.proxy_ports_cache, pair_id)
    {:noreply, %{state | proxy_ports_cache: new_cache}}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{socket: socket} = state) do
    # Offload query parsing and processing to Task.Supervisor to free the GenServer single thread immediately
    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
      case Packet.parse(packet) do
        {:ok, query} ->
          process_query_fast_path(socket, ip, port, packet, query, state)

        {:error, _reason} ->
          if byte_size(packet) >= 12 do
            <<id::binary-size(2), _::binary>> = packet
            err_resp = <<id::binary, 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
            :gen_udp.send(socket, ip, port, err_resp)
          end
      end
    end)

    {:noreply, state}
  end

  # Handle asynchronous responses from upstream DNS servers
  @impl true
  def handle_info(
        {:udp, upstream_socket, upstream_ip, upstream_port, packet},
        state
      ) do
    is_our_upstream_socket? =
      is_tuple(state.upstream_sockets) and
        upstream_socket in Tuple.to_list(state.upstream_sockets)

    if is_our_upstream_socket? and byte_size(packet) >= 12 do
      <<tx_id::16, _::binary>> = packet

      case :ets.lookup(state.pending_table, tx_id) do
        [
          {_,
           {client_ip, client_port, original_query, sent_at, target_upstreams, current_index,
            original_tx_id}}
        ] ->
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

            # Cleanup pending query immediately in ETS
            :ets.delete(state.pending_table, tx_id)
            {:noreply, state}
          else
            {:noreply, state}
          end

        [] ->
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
    case :ets.lookup(state.pending_table, tx_id) do
      [
        {_,
         {client_ip, client_port, original_query, _sent_at, target_upstreams, current_index,
          original_tx_id}}
      ] ->
        upstream = elem(target_upstreams, current_index)

        expected_url =
          case upstream do
            {:doh, u} -> u
            {:doh_proxy, u, _pair_id} -> u
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

            # Send response packet back to client immediately
            send_client_response(client_socket, client_ip, client_port, client_packet)

            # Calculate latency and cast back to server
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
                {:doh, _} -> "DoH (#{extract_host(url)})"
                {:doh_proxy, _, _} -> "DoH Proxy (#{extract_host(url)})"
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

          # Cleanup pending query
          :ets.delete(state.pending_table, tx_id)
          {:noreply, state}
        else
          {:noreply, state}
        end

      [] ->
        {:noreply, state}
    end
  end

  # Handle periodic lazy timeout cleanups & fallback triggering (every 1s)
  @impl true
  def handle_info(:clean_timeouts, state) do
    now = System.monotonic_time(:millisecond)
    records = :ets.tab2list(state.pending_table)

    new_state =
      Enum.reduce(records, state, fn {tx_id, info}, acc_state ->
        {_client_ip, _client_port, _original_query, sent_at, target_upstreams, current_index,
         _original_tx_id} = info

        current_upstream = elem(target_upstreams, current_index)

        timeout_limit =
          case current_upstream do
            {:doh, _} -> 4000
            {:doh_proxy, _, _} -> 4000
            _ -> 2000
          end

        if now - sent_at >= timeout_limit do
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
  def handle_info({:udp_passive, socket}, state) do
    Logger.info("DNS Server: UDP socket went passive, re-enabling active: 100")
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

          # 3. Match dynamic blocklists if not matched by custom rules
          {action, redirect_val, block_reason, blocklist_id} =
            if is_nil(action) and config.enabled do
              blocklists_list =
                case config.blocklists do
                  %Ecto.Association.NotLoaded{} -> []
                  nil -> []
                  list when is_list(list) -> list
                end

              enabled_blocklist_ids =
                blocklists_list
                |> Enum.filter(& &1.enabled)
                |> Enum.map(& &1.id)

              matched_id =
                if enabled_blocklist_ids != [] do
                  Filter.match_any_ets_blocklist_cached?(query.domain, enabled_blocklist_ids)
                else
                  nil
                end

              if matched_id do
                matched_name =
                  case Enum.find(blocklists_list, &(&1.id == matched_id)) do
                    nil -> "blocklist"
                    b -> b.name
                  end

                {"block", nil, matched_name, matched_id}
              else
                {nil, nil, nil, nil}
              end
            else
              {action, redirect_val, block_reason, nil}
            end

          case action do
            "block" ->
              resp = Packet.build_nxdomain(query.id, query.query_record)

              answer_log_info =
                case block_reason do
                  "adult" -> "NXDOMAIN (Adult Filter)"
                  "custom_rule" -> "NXDOMAIN (Custom Rule)"
                  nil -> "NXDOMAIN"
                  name -> "NXDOMAIN (#{name})"
                end

              # Store blocks in cache with 5s TTL
              Cache.store(
                profile_id,
                query.domain,
                query.qtype,
                resp,
                "blocked",
                answer_log_info,
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
                  status: "blocked",
                  answer: answer_log_info,
                  resolver: "Local Filter",
                  block_reason: block_reason,
                  blocklist_id: blocklist_id,
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

            "forward_proxy" when not is_nil(redirect_val) ->
              target_upstreams = select_upstreams_for_domain(query.domain, upstreams)
              first_upstream = List.first(target_upstreams)

              case first_upstream do
                {:udp, _} ->
                  {proxy_ports, state} = get_proxy_ports_for_pair(redirect_val, state)

                  case proxy_ports do
                    {:ok, _http_port, socks5_port} when not is_nil(socks5_port) ->
                      async_forward_to_udp_proxy(
                        socket,
                        ip,
                        port,
                        packet,
                        query,
                        first_upstream,
                        socks5_port,
                        redirect_val,
                        state
                      )

                    _ ->
                      Logger.error(
                        "DNS Server: Failed to get SOCKS5 proxy port for pair #{redirect_val}, returning SERVFAIL to prevent DNS leak"
                      )

                      servfail =
                        Packet.build_nxdomain(query.id, query.query_record)
                        |> Packet.patch_rcode(2)

                      send_client_response(socket, ip, port, servfail)

                      :telemetry.execute(
                        [:hermit, :dns, :query],
                        %{duration: 0},
                        %{
                          profile_id: state.profile_id,
                          config_id: state.config.id,
                          client_ip: ip,
                          domain: query.domain,
                          qtype: query.qtype,
                          status: "resolved",
                          answer: "SERVFAIL",
                          resolver: "Proxy Failure (UDP)",
                          enable_query_logging: state.config.enable_query_logging
                        }
                      )

                      state
                  end

                {:doh, url} ->
                  {proxy_ports, state} = get_proxy_ports_for_pair(redirect_val, state)

                  case proxy_ports do
                    {:ok, http_port, _socks5_port} when not is_nil(http_port) ->
                      async_forward_to_proxy(
                        socket,
                        ip,
                        port,
                        packet,
                        query,
                        url,
                        http_port,
                        redirect_val,
                        state
                      )

                    _ ->
                      Logger.error(
                        "DNS Server: Failed to get HTTP proxy port for pair #{redirect_val}, returning SERVFAIL to prevent DNS leak"
                      )

                      servfail =
                        Packet.build_nxdomain(query.id, query.query_record)
                        |> Packet.patch_rcode(2)

                      send_client_response(socket, ip, port, servfail)

                      :telemetry.execute(
                        [:hermit, :dns, :query],
                        %{duration: 0},
                        %{
                          profile_id: state.profile_id,
                          config_id: state.config.id,
                          client_ip: ip,
                          domain: query.domain,
                          qtype: query.qtype,
                          status: "resolved",
                          answer: "SERVFAIL",
                          resolver: "Proxy Failure (DoH)",
                          enable_query_logging: state.config.enable_query_logging
                        }
                      )

                      state
                  end

                _ ->
                  doh_url = "https://cloudflare-dns.com/dns-query"

                  {proxy_ports, state} = get_proxy_ports_for_pair(redirect_val, state)

                  case proxy_ports do
                    {:ok, http_port, _socks5_port} when not is_nil(http_port) ->
                      async_forward_to_proxy(
                        socket,
                        ip,
                        port,
                        packet,
                        query,
                        doh_url,
                        http_port,
                        redirect_val,
                        state
                      )

                    _ ->
                      Logger.error(
                        "DNS Server: Failed to get HTTP proxy port for pair #{redirect_val}, returning SERVFAIL to prevent DNS leak"
                      )

                      servfail =
                        Packet.build_nxdomain(query.id, query.query_record)
                        |> Packet.patch_rcode(2)

                      send_client_response(socket, ip, port, servfail)

                      :telemetry.execute(
                        [:hermit, :dns, :query],
                        %{duration: 0},
                        %{
                          profile_id: state.profile_id,
                          config_id: state.config.id,
                          client_ip: ip,
                          domain: query.domain,
                          qtype: query.qtype,
                          status: "resolved",
                          answer: "SERVFAIL",
                          resolver: "Proxy Failure (DoH Fallback)",
                          enable_query_logging: state.config.enable_query_logging
                        }
                      )

                      state
                  end
              end

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
    sorted_upstreams =
      sort_upstreams_by_priority(target_upstreams, state.upstreams, state.upstreams_map)

    if sorted_upstreams == [] do
      # Return SERVFAIL if no upstreams configured
      servfail = Packet.build_nxdomain(query.id, query.query_record)
      servfail = Packet.patch_rcode(servfail, 2)
      send_client_response(socket, ip, port, servfail)
      state
    else
      # Sinh ngẫu nhiên transaction ID 16-bit để tránh xung đột khi chạy đa luồng
      upstream_tx_id = :rand.uniform(65536) - 1
      upstream_tx_id_bin = <<upstream_tx_id::16>>

      # Rewrite Transaction ID trong gói tin gửi đi
      <<_old_id::binary-size(2), rest_packet::binary>> = packet
      rewritten_packet = upstream_tx_id_bin <> rest_packet

      now = System.monotonic_time(:millisecond)

      # Send asynchronously to the first upstream in the sorted list (index 0)
      first_upstream = hd(sorted_upstreams)

      async_send_to_upstream(
        state.upstream_sockets,
        state.doh_client,
        first_upstream,
        rewritten_packet,
        state.server_pid
      )

      # Save query context in pending_queries table
      # Struct: {client_ip, client_port, original_query, sent_at, target_upstreams_tuple, current_index, original_tx_id}
      upstreams_tuple = List.to_tuple(sorted_upstreams)
      query_info = {ip, port, query, now, upstreams_tuple, 0, query.id}
      :ets.insert(state.pending_table, {upstream_tx_id, query_info})

      state
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

  defp async_send_to_upstream(
         upstream_sockets,
         _doh_client,
         {:udp, {ip, port}},
         packet,
         _server_pid
       )
       when is_tuple(upstream_sockets) do
    # For UDP upstreams with specific port, send immediately using a socket from the pool
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, port, packet)
  end

  defp async_send_to_upstream(upstream_sockets, _doh_client, {:udp, ip}, packet, _server_pid)
       when is_tuple(upstream_sockets) and is_tuple(ip) do
    # For UDP upstreams with only IP, default port to 53
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, 53, packet)
  end

  defp async_send_to_upstream(_upstream_sockets, doh_client, {:doh, url}, packet, server_pid) do
    # For DoH upstreams, send asynchronously using a Task
    # Since HTTP Req calls are blocking, we task them to avoid blocking the GenServer
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
    case :ets.lookup(state.pending_table, tx_id) do
      [
        {_,
         {client_ip, client_port, original_query, sent_at, target_upstreams, current_index,
          original_tx_id}}
      ] ->
        failed_upstream = elem(target_upstreams, current_index)

        # 1. Phạt độ trễ ngay lập tức trong state của GenServer
        new_upstreams_map =
          case failed_upstream do
            {:doh_proxy, _, _} -> state.upstreams_map
            _ -> Map.put(state.upstreams_map, failed_upstream, 2000)
          end

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

          async_send_to_upstream(
            state.upstream_sockets,
            state.doh_client,
            next_upstream,
            packet,
            state.server_pid
          )

          # Cập nhật thông tin truy vấn trong pending_queries
          now = System.monotonic_time(:millisecond)

          updated_info =
            {client_ip, client_port, original_query, now, target_upstreams, next_index,
             original_tx_id}

          :ets.insert(state.pending_table, {tx_id, updated_info})

          state
        else
          # 3. Hết DNS dự phòng: Thử tìm trong cache stale trước khi trả SERVFAIL! (Serve-Stale - RFC 8767)
          case Cache.lookup(state.profile_id, original_query.domain, original_query.qtype, true) do
            {:stale, stale_packet, status, answer_log_info} ->
              # Set TTL cho stale packet về 30s (RFC 8767) để client không cache quá lâu
              stale_packet = Packet.patch_stale_ttl(stale_packet, 30)
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

          :ets.delete(state.pending_table, tx_id)
          state
        end

      [] ->
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

  defp query_upstream(other, _packet) do
    Logger.warning("DNS Server: query_upstream called with unsupported type: #{inspect(other)}")
    {:error, :unsupported_upstream_type}
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

  defp get_proxy_ports_for_pair(pair_id, state) do
    if mock?() do
      {{:ok, 8080, 1080}, state}
    else
      ensure_proxy_cache_table_exists()

      case :ets.lookup(:dns_proxy_cache, {:ports, pair_id}) do
        [{_, {http_port, socks5_port}}] ->
          {{:ok, http_port, socks5_port}, state}

        [] ->
          # Fallback: if not in cache yet, read from disk and update cache
          case read_proxy_ports_from_disk(pair_id) do
            {:ok, http_port, socks5_port} ->
              :ets.insert(:dns_proxy_cache, {{:ports, pair_id}, {http_port, socks5_port}})
              {{:ok, http_port, socks5_port}, state}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end
  end

  defp pre_populate_proxy_ports_cache do
    try do
      import Ecto.Query
      pairs = Hermit.Repo.all(from(p in Hermit.Vpn.VpnPair, where: p.status == "running"))
      ensure_proxy_cache_table_exists()

      Enum.reduce(pairs, %{}, fn pair, acc ->
        case read_proxy_ports_from_disk(pair.pair_id) do
          {:ok, http_port, socks5_port} ->
            :ets.insert(:dns_proxy_cache, {{:ports, pair.pair_id}, {http_port, socks5_port}})
            Map.put(acc, pair.pair_id, {http_port, socks5_port})

          _ ->
            acc
        end
      end)
    rescue
      _ -> %{}
    end
  end

  defp read_proxy_ports_from_disk(pair_id) do
    storage_base =
      case Application.get_env(:hermit, :storage, []) |> Keyword.get(:base_path) do
        nil -> "/app/storage"
        path -> path
      end

    storage_dir = Path.join(storage_base, to_string(pair_id))
    proxy_info_path = Path.join(storage_dir, "proxy_info.json")

    case File.read(proxy_info_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"http_port" => http_port, "socks5_port" => socks5_port}} ->
            {:ok, http_port, socks5_port}

          {:ok, %{"http_port" => http_port}} ->
            {:ok, http_port, nil}

          _ ->
            {:error, :invalid_proxy_info}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_make_proxy_client(proxy_port, state) do
    ensure_proxy_cache_table_exists()

    case :ets.lookup(:dns_proxy_cache, {:client, proxy_port}) do
      [{_, client}] ->
        {client, state}

      [] ->
        client =
          Req.new(
            connect_options: [
              protocols: [:http2, :http1],
              proxy: {:http, "127.0.0.1", proxy_port, []}
            ],
            retry: false,
            receive_timeout: 4000
          )

        :ets.insert(:dns_proxy_cache, {{:client, proxy_port}, client})
        {client, state}
    end
  end

  defp ensure_proxy_cache_table_exists do
    if :ets.info(:dns_proxy_cache) == :undefined do
      try do
        :ets.new(:dns_proxy_cache, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: :auto
        ])
      rescue
        _ -> :ok
      end
    end
  end

  defp async_forward_to_proxy(
         _socket,
         ip,
         port,
         packet,
         query,
         doh_url,
         proxy_port,
         pair_id,
         state
       ) do
    {doh_client, state} = get_or_make_proxy_client(proxy_port, state)
    proxy_url = "http://127.0.0.1:#{proxy_port}"

    server_pid = state.server_pid
    <<_tx_id::16, _::binary>> = packet

    # Sinh ngẫu nhiên transaction ID 16-bit
    upstream_tx_id = :rand.uniform(65536) - 1
    upstream_tx_id_bin = <<upstream_tx_id::16>>

    <<_old_id::binary-size(2), rest_packet::binary>> = packet
    rewritten_packet = upstream_tx_id_bin <> rest_packet

    now = System.monotonic_time(:millisecond)

    Task.start(fn ->
      start = System.monotonic_time()

      case Req.post(doh_client,
             url: doh_url,
             headers: [
               {"content-type", "application/dns-message"},
               {"accept", "application/dns-message"}
             ],
             body: rewritten_packet
           ) do
        {:ok, %{status: 200, body: resp_packet}} ->
          <<upstream_tx_id_resp::16, _::binary>> = resp_packet

          final_packet =
            if upstream_tx_id_resp != upstream_tx_id do
              <<_::16, rest::binary>> = resp_packet
              upstream_tx_id_bin <> rest
            else
              resp_packet
            end

          duration =
            System.convert_time_unit(
              System.monotonic_time() - start,
              :native,
              :millisecond
            )

          send(server_pid, {:doh_response, upstream_tx_id, doh_url, final_packet, duration})

        other ->
          Logger.warning(
            "DNS Server: DoH proxy query to #{doh_url} via #{proxy_url} failed: #{inspect(other)}"
          )

          send(server_pid, {:doh_failure, upstream_tx_id, doh_url})
      end
    end)

    upstreams_tuple = {{:doh_proxy, doh_url, pair_id}}
    query_info = {ip, port, query, now, upstreams_tuple, 0, query.id}
    :ets.insert(state.pending_table, {upstream_tx_id, query_info})

    state
  end

  defp async_forward_to_udp_proxy(
         _socket,
         ip,
         port,
         packet,
         query,
         udp_upstream,
         socks5_port,
         pair_id,
         state
       ) do
    socks5_ip = "127.0.0.1"
    server_pid = state.server_pid
    <<_tx_id::16, _::binary>> = packet

    # Sinh ngẫu nhiên transaction ID 16-bit
    upstream_tx_id = :rand.uniform(65536) - 1
    upstream_tx_id_bin = <<upstream_tx_id::16>>

    <<_old_id::binary-size(2), rest_packet::binary>> = packet
    rewritten_packet = upstream_tx_id_bin <> rest_packet

    now = System.monotonic_time(:millisecond)

    {target_ip, target_port} =
      case udp_upstream do
        {:udp, {tip, tport}} -> {tip, tport}
        {:udp, tip} -> {tip, 53}
      end

    target_ip_str = ip_to_string(target_ip)
    udp_proxy_url = "udp://#{target_ip_str}:#{target_port}"

    Task.start(fn ->
      start = System.monotonic_time()

      case socks5_udp_resolve(socks5_ip, socks5_port, target_ip, target_port, rewritten_packet) do
        {:ok, resp_packet} ->
          <<upstream_tx_id_resp::16, _::binary>> = resp_packet

          final_packet =
            if upstream_tx_id_resp != upstream_tx_id do
              <<_::16, rest::binary>> = resp_packet
              upstream_tx_id_bin <> rest
            else
              resp_packet
            end

          duration =
            System.convert_time_unit(
              System.monotonic_time() - start,
              :native,
              :millisecond
            )

          send(server_pid, {:doh_response, upstream_tx_id, udp_proxy_url, final_packet, duration})

        other ->
          Logger.warning(
            "DNS Server: UDP proxy query to #{udp_proxy_url} via SOCKS5 port #{socks5_port} failed: #{inspect(other)}"
          )

          send(server_pid, {:doh_failure, upstream_tx_id, udp_proxy_url})
      end
    end)

    upstreams_tuple = {{:doh_proxy, udp_proxy_url, pair_id}}
    query_info = {ip, port, query, now, upstreams_tuple, 0, query.id}
    :ets.insert(state.pending_table, {upstream_tx_id, query_info})

    state
  end

  defp socks5_udp_resolve(socks5_ip, socks5_port, target_ip, target_port, packet) do
    if mock?() do
      # Mock SOCKS5 resolution for testing
      case Packet.parse(packet) do
        {:ok, %{id: id_bin, query_record: query_rec}} ->
          Process.sleep(50)
          {:ok, Packet.build_a_response(id_bin, query_rec, "127.0.0.9")}

        _ ->
          {:error, :mock_parse_failed}
      end
    else
      # Real SOCKS5 resolution via DNS-over-TCP to port 53 of the upstream DNS
      tcp_opts = [:binary, active: false, packet: 0]

      case :gen_tcp.connect(String.to_charlist(socks5_ip), socks5_port, tcp_opts, 3000) do
        {:ok, tcp_socket} ->
          try do
            do_socks5_tcp_dns_resolve(tcp_socket, target_ip, target_port, packet)
          after
            :gen_tcp.close(tcp_socket)
          end

        {:error, reason} ->
          {:error, {:tcp_connect_failed, reason}}
      end
    end
  end

  defp do_socks5_tcp_dns_resolve(tcp_socket, target_ip, target_port, packet) do
    # 1. Handshake
    with :ok <- :gen_tcp.send(tcp_socket, <<5, 1, 0>>),
         {:ok, <<5, 0>>} <- :gen_tcp.recv(tcp_socket, 2, 3000) do
      # 2. Build SOCKS5 CONNECT request
      {atyp, addr_bin} =
        case target_ip do
          {ip1, ip2, ip3, ip4} ->
            {1, <<ip1, ip2, ip3, ip4>>}

          {ip1, ip2, ip3, ip4, ip5, ip6, ip7, ip8} ->
            {4, <<ip1::16, ip2::16, ip3::16, ip4::16, ip5::16, ip6::16, ip7::16, ip8::16>>}
        end

      connect_req = <<5, 1, 0, atyp>> <> addr_bin <> <<target_port::16>>

      # 3. Send CONNECT and receive CONNECT response
      with :ok <- :gen_tcp.send(tcp_socket, connect_req),
           {:ok, <<5, 0, 0, atyp_resp>>} <- :gen_tcp.recv(tcp_socket, 4, 3000),
           {:ok, _bnd_addr, _bnd_port} <- read_socks5_addr_port(tcp_socket, atyp_resp) do
        # 4. Connection is established! Send DNS query over TCP
        # DNS-over-TCP packet is prefixed with 16-bit length
        len = byte_size(packet)
        tcp_packet = <<len::16>> <> packet

        with :ok <- :gen_tcp.send(tcp_socket, tcp_packet),
             {:ok, <<resp_len::16>>} <- :gen_tcp.recv(tcp_socket, 2, 4000),
             {:ok, resp_packet} <- :gen_tcp.recv(tcp_socket, resp_len, 4000) do
          {:ok, resp_packet}
        else
          {:error, reason} -> {:error, {:dns_tcp_io_failed, reason}}
        end
      else
        {:ok, <<5, status, 0, _atyp_resp>>} -> {:error, {:socks_connect_failed, status}}
        {:error, reason} -> {:error, {:socks_handshake_failed, reason}}
        other -> {:error, {:socks_handshake_invalid_resp, other}}
      end
    else
      {:error, reason} -> {:error, {:socks_greeting_failed, reason}}
      other -> {:error, {:socks_greeting_invalid_resp, other}}
    end
  end

  defp read_socks5_addr_port(socket, 1) do
    case :gen_tcp.recv(socket, 6, 2000) do
      {:ok, <<ip1, ip2, ip3, ip4, port::16>>} ->
        {:ok, {ip1, ip2, ip3, ip4}, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_socks5_addr_port(socket, 3) do
    case :gen_tcp.recv(socket, 1, 2000) do
      {:ok, <<len>>} ->
        case :gen_tcp.recv(socket, len + 2, 2000) do
          {:ok, <<domain::binary-size(len), port::16>>} ->
            {:ok, String.to_charlist(domain), port}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_socks5_addr_port(socket, 4) do
    case :gen_tcp.recv(socket, 18, 2000) do
      {:ok, <<ip_bin::binary-size(16), port::16>>} ->
        <<ip1::16, ip2::16, ip3::16, ip4::16, ip5::16, ip6::16, ip7::16, ip8::16>> = ip_bin
        {:ok, {ip1, ip2, ip3, ip4, ip5, ip6, ip7, ip8}, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_socks5_addr_port(_socket, other) do
    {:error, {:unknown_atyp, other}}
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
