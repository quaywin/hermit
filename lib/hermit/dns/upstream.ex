defmodule Hermit.Dns.Upstream do
  @moduledoc """
  Handles upstream DNS parsing, priority/health sorting, UDP/DoH forwarding,
  failover with Serve-Stale (RFC 8767), ECS injection, and response post-processing.
  """
  require Logger

  alias Hermit.Dns.Cache
  alias Hermit.Dns.Packet
  alias Hermit.Dns.PendingQueries

  def parse_upstreams(upstream_str) do
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

  def parse_ip_and_port(val) do
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

  def extract_host(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when not is_nil(host) -> host
      _ -> "DoH Server"
    end
  end

  def send_client_response(socket, ip, port, resp) do
    if is_tuple(port) do
      GenServer.reply(port, {:ok, resp})
    else
      :gen_udp.send(socket, ip, port, resp)
    end
  end

  def maybe_inject_ecs(packet, client_ip, state) do
    if Map.get(state.config, :enable_ecs, false) do
      fallback_ip = Map.get(state.config, :ecs_fallback_ip)

      case Packet.inject_ecs(packet, client_ip, fallback_ip) do
        {:ok, ecs_packet} -> ecs_packet
        _ -> packet
      end
    else
      packet
    end
  end

  def async_forward(socket, ip, port, packet, query, target_upstreams, state) do
    sorted_upstreams = sort_by_priority(target_upstreams, state.upstreams, state.upstreams_map)

    if sorted_upstreams == [] do
      servfail = Packet.build_servfail(query.id, query.query_record)
      send_client_response(socket, ip, port, servfail)
      state
    else
      now = System.monotonic_time(:millisecond)
      upstreams_tuple = List.to_tuple(sorted_upstreams)
      query_info = {ip, port, query, now, upstreams_tuple, 0, query.id}

      upstream_tx_id = PendingQueries.register(state.pending_table, query_info)
      upstream_tx_id_bin = <<upstream_tx_id::16>>

      <<_old_id::binary-size(2), rest_packet::binary>> = packet
      rewritten_packet = upstream_tx_id_bin <> rest_packet
      final_packet = maybe_inject_ecs(rewritten_packet, ip, state)

      first_upstream = hd(sorted_upstreams)

      async_send(
        state.upstream_sockets,
        state.doh_client,
        first_upstream,
        final_packet,
        state.server_pid
      )

      state
    end
  end

  def sort_by_priority(target_upstreams, upstreams_order, upstreams_map) do
    {healthy, penalized} =
      Enum.split_with(target_upstreams, fn upstream ->
        latency = Map.get(upstreams_map, upstream, 20)
        latency < 2000
      end)

    sorted_healthy =
      Enum.sort_by(healthy, fn upstream ->
        Enum.find_index(upstreams_order, &(&1 == upstream)) || 999
      end)

    sorted_penalized =
      Enum.sort_by(penalized, fn upstream ->
        Enum.find_index(upstreams_order, &(&1 == upstream)) || 999
      end)

    sorted_healthy ++ sorted_penalized
  end

  def async_send(upstream_sockets, _doh_client, {:udp, {ip, port}}, packet, _server_pid)
      when is_tuple(upstream_sockets) do
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, port, packet)
  end

  def async_send(upstream_sockets, _doh_client, {:udp, ip}, packet, _server_pid)
      when is_tuple(upstream_sockets) and is_tuple(ip) do
    <<tx_id::16, _::binary>> = packet
    socket_index = :erlang.phash2(tx_id, tuple_size(upstream_sockets))
    selected_socket = elem(upstream_sockets, socket_index)
    :gen_udp.send(selected_socket, ip, 53, packet)
  end

  def async_send(_upstream_sockets, doh_client, {:doh, url}, packet, server_pid) do
    <<tx_id::16, _::binary>> = packet

    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
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

          send(server_pid, {:doh_response, tx_id, url, final_packet, duration})

        other ->
          Logger.warning("DNS Server: DoH query to upstream #{url} failed: #{inspect(other)}")
          send(server_pid, {:doh_failure, tx_id, url})
      end
    end)
  end

  def handle_failure(tx_id, state) do
    case :ets.lookup(state.pending_table, tx_id) do
      [
        {_,
         {client_ip, client_port, original_query, sent_at, target_upstreams, current_index,
          original_tx_id}}
      ] ->
        failed_upstream = elem(target_upstreams, current_index)

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
          next_upstream = elem(target_upstreams, next_index)
          packet = Packet.build_query_packet(tx_id, original_query.query_record)

          async_send(
            state.upstream_sockets,
            state.doh_client,
            next_upstream,
            packet,
            state.server_pid
          )

          now = System.monotonic_time(:millisecond)

          updated_info =
            {client_ip, client_port, original_query, now, target_upstreams, next_index,
             original_tx_id}

          :ets.insert(state.pending_table, {tx_id, updated_info})
          state
        else
          is_internal = Hermit.Vpn.SniProxy.IpResolver.internal_ip?(client_ip)

          # Serve-Stale (RFC 8767) before returning SERVFAIL
          case Cache.lookup(
                 state.profile_id,
                 is_internal,
                 original_query.domain,
                 original_query.qtype,
                 true
               ) do
            {:stale, stale_packet, status, answer_log_info} ->
              stale_packet = Packet.patch_stale_ttl(stale_packet, 30)
              <<_::binary-size(2), rest_packet::binary>> = stale_packet
              client_packet = original_tx_id <> rest_packet
              send_client_response(state.socket, client_ip, client_port, client_packet)

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
              servfail = Packet.build_servfail(original_tx_id, original_query.query_record)
              send_client_response(state.socket, client_ip, client_port, servfail)

              Cache.store(
                state.profile_id,
                is_internal,
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

  def offload_post_processing(
        server_pid,
        profile_id,
        config_id,
        enable_query_logging,
        client_ip,
        original_query,
        upstream,
        packet,
        duration
      ) do
    Task.Supervisor.start_child(Hermit.Dns.TaskSupervisor, fn ->
      GenServer.cast(server_pid, {:update_latency, upstream, duration})

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

      is_internal = Hermit.Vpn.SniProxy.IpResolver.internal_ip?(client_ip)

      Cache.store(
        profile_id,
        is_internal,
        original_query.domain,
        original_query.qtype,
        packet,
        "resolved",
        answer_log_info,
        ttl
      )

      resolver_tag =
        case upstream do
          {:udp, {ip_addr, port}} -> "UDP (#{Packet.ip_to_string(ip_addr)}:#{port})"
          {:udp, ip_addr} -> "UDP (#{Packet.ip_to_string(ip_addr)})"
          {:doh, url} -> "DoH (#{extract_host(url)})"
          {:doh_proxy, url, _} -> "DoH Proxy (#{extract_host(url)})"
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
  end
end
