defmodule Hermit.Dns.Server do
  use GenServer
  require Logger
  alias Hermit.Dns.Packet

  @table :dns_query_logs

  # Lightweight built-in filters
  @ad_trackers MapSet.new([
    "doubleclick.net", "google-analytics.com", "adservice.google.com",
    "adnxs.com", "adsrvr.org", "quantserve.com", "scorecardresearch.com",
    "amplitude.com", "mixpanel.com", "telemetry.mozilla.org",
    "adcolony.com", "applovin.com", "unityads.unity3d.com"
  ])

  @adult_domains MapSet.new([
    "pornhub.com", "xvideos.com", "xnxx.com", "redtube.com", "youporn.com",
    "chaturbate.com", "stripchat.com", "livejasmin.com", "onlyfans.com"
  ])

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    port = opts[:port] || 5353
    # Try opening UDP socket on port
    case :gen_udp.open(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("Elixir DNS Server listening on UDP port #{port}")
        {:ok, %{socket: socket, port: port}}

      {:error, reason} ->
        Logger.error("Failed to start Elixir DNS Server on port #{port}: #{inspect(reason)}")
        # Don't fail application boot, start in passive offline state
        {:ok, %{socket: nil, port: port}}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{socket: socket} = state) do
    # Handle incoming query asynchronously to avoid blocking the UDP receive loop
    Task.start(fn ->
      process_query(socket, ip, port, packet)
    end)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- DNS Core Processing ---

  defp process_query(socket, ip, port, packet) do
    start_time = System.monotonic_time()

    case Packet.parse(packet) do
      {:ok, query} ->
        client_ip_str = ip_to_string(ip)
        config = Hermit.Vpn.DnsConfig.get_global()

        # Parse upstreams
        upstreams = parse_upstreams(config.upstream_dns)

        if config.enabled do
          # 1. Match custom rules
          custom_rules = get_custom_rules(config.custom_rules)
          {action, redirect_val} = match_custom_rules(query.domain, custom_rules)

          # 2. Match built-in blocklists if not matched by custom rules
          {action, redirect_val} =
            if is_nil(action) do
              cond do
                config.block_ads and match_domain_set?(query.domain, @ad_trackers) ->
                  {"block", nil}

                config.block_adult and match_domain_set?(query.domain, @adult_domains) ->
                  {"block", nil}

                true ->
                  {nil, nil}
              end
            else
              {action, redirect_val}
            end

          # Execute Action
          duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

          case action do
            "block" ->
              resp = Packet.build_nxdomain(query.id, query.question_section)
              :gen_udp.send(socket, ip, port, resp)
              log_and_broadcast(client_ip_str, query.domain, query.qtype, "blocked", "NXDOMAIN", duration_ms)

            "redirect" when not is_nil(redirect_val) ->
              # Only redirect A (IPv4) queries, otherwise return NXDOMAIN or bypass
              if query.qtype == :A do
                resp = Packet.build_a_response(query.id, query.question_section, redirect_val)
                :gen_udp.send(socket, ip, port, resp)
                log_and_broadcast(client_ip_str, query.domain, query.qtype, "redirected", redirect_val, duration_ms)
              else
                # Default AAAA / other queries to NXDOMAIN for blocked/redirected domains
                resp = Packet.build_nxdomain(query.id, query.question_section)
                :gen_udp.send(socket, ip, port, resp)
                log_and_broadcast(client_ip_str, query.domain, query.qtype, "redirected", "NXDOMAIN", duration_ms)
              end

            _ ->
              # "bypass" or no match -> forward to upstream
              forward_to_upstream(socket, ip, port, packet, query, client_ip_str, upstreams, start_time)
          end
        else
          # DNS Filtering is globally disabled, just forward to upstream
          forward_to_upstream(socket, ip, port, packet, query, client_ip_str, upstreams, start_time)
        end

      {:error, _reason} ->
        # Send Format Error (RCODE 1)
        if byte_size(packet) >= 12 do
          <<id::binary-size(2), _::binary>> = packet
          err_resp = <<id::binary, 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
          :gen_udp.send(socket, ip, port, err_resp)
        end
    end
  end

  defp forward_to_upstream(socket, ip, port, packet, query, client_ip_str, upstreams, start_time) do
    case try_upstreams(upstreams, packet) do
      {:ok, resp_packet} ->
        # Forward response back to the client
        :gen_udp.send(socket, ip, port, resp_packet)
        duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
        
        # Try to parse response answers to find IPs
        answer_ip = parse_resolved_ip(resp_packet)
        log_and_broadcast(client_ip_str, query.domain, query.qtype, "resolved", answer_ip, duration_ms)

      {:error, _} ->
        # Send Server Failure (RCODE 2)
        duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
        servfail = Packet.build_nxdomain(query.id, query.question_section)
        # Change RCODE byte in header to 2 (SERVFAIL)
        servfail = patch_rcode(servfail, 2)
        :gen_udp.send(socket, ip, port, servfail)
        log_and_broadcast(client_ip_str, query.domain, query.qtype, "resolved", "SERVFAIL", duration_ms)
    end
  end

  # Helper to overwrite the RCODE field in the header
  defp patch_rcode(<<id::binary-size(2), _flags::binary-size(2), rest::binary>>, rcode) do
    # Flags byte 1: 0x81 (Response, Recursion Desired)
    # Flags byte 2: 0x80 (Recursion Available) | rcode
    flags2 = 0x80 + rcode
    <<id::binary, 0x81, flags2, rest::binary>>
  end

  # Upstream forwarding client loop
  defp try_upstreams([], _packet), do: {:error, :no_upstreams}
  defp try_upstreams([upstream | rest], packet) do
    # Open dynamic client UDP socket
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, client_sock} ->
        try do
          case :gen_udp.send(client_sock, upstream, 53, packet) do
            :ok ->
              case :gen_udp.recv(client_sock, 0, 2000) do
                {:ok, {_ip, 53, resp_packet}} ->
                  {:ok, resp_packet}
                _ ->
                  try_upstreams(rest, packet)
              end
            _ ->
              try_upstreams(rest, packet)
          end
        after
          :gen_udp.close(client_sock)
        end

      _ ->
        try_upstreams(rest, packet)
    end
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
    domain == domain && (MapSet.member?(set, domain) or
      Enum.any?(set, fn suffix -> String.ends_with?(domain, "." <> suffix) end))
  end

  # --- Log Parsing & Recording ---

  defp parse_resolved_ip(resp_packet) do
    # Try parsing the first A record in the answer section to show in the log
    # For simplicity, if we cannot parse it easily, we just output "Resolved"
    case Packet.parse(resp_packet) do
      {:ok, _parsed} ->
        # Simple extraction helper or just "Resolved"
        "Resolved"
      _ ->
        "Resolved"
    end
  end

  defp log_and_broadcast(client_ip, domain, qtype, status, answer, duration_ms) do
    log_data = %{
      "pair_id" => "global", # keeping pair_id key for logs system compatibility
      "client_ip" => client_ip,
      "domain" => domain,
      "type" => Packet.qtype_to_string(qtype),
      "status" => status,
      "answer" => answer,
      "duration" => duration_ms,
      "timestamp" => System.system_time(:second)
    }

    # Store in ETS table
    counter = System.unique_integer([:monotonic])
    :ets.insert(@table, {{"global", counter}, log_data})
    prune_logs("global")

    # Broadcast to LiveView
    Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:global", {:dns_log, log_data})
  end

  defp prune_logs(pair_id) do
    pattern = {{pair_id, :"$1"}, :_}
    keys = :ets.select(@table, [{pattern, [], [:"$1"]}])

    if length(keys) > 200 do
      sorted_keys = Enum.sort(keys)
      to_delete_count = length(sorted_keys) - 200
      
      Enum.take(sorted_keys, to_delete_count)
      |> Enum.each(fn counter ->
        :ets.delete(@table, {pair_id, counter})
      end)
    end
  end

  # --- General IP parsing ---

  defp parse_upstreams(upstream_str) do
    upstream_str
    |> String.split([",", " "], trim: true)
    |> Enum.map(fn ip ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, addr} -> addr
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ip_to_string(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      charlist when is_list(charlist) -> List.to_string(charlist)
      _ -> "unknown"
    end
  end
  defp ip_to_string(other), do: to_string(other)
end
