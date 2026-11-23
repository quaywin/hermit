defmodule Hermit.Dns.FastPath do
  @moduledoc """
  Lock-free local DNS resolution fast path (IPv6 blocking, ETS cache hits,
  custom rules, and Smart DNS routing).
  """

  alias Hermit.Dns.Cache
  alias Hermit.Dns.Packet
  alias Hermit.Dns.Rules

  @doc """
  Directly resolves a DNS query from the fast path (Cache hit, IPv6 block, Custom Rule block/redirect,
  or Smart Route match) without message-passing or spawning tasks.
  Returns `{:ok, response_packet}` if resolved locally, or `:miss` if resolution requires upstream forwarding.
  """
  @spec resolve_fast_path(integer(), binary(), term()) :: {:ok, binary()} | :miss
  def resolve_fast_path(endpoint_id, packet, client_ip) do
    if :ets.info(:inbound_profiles_cache) != :undefined do
      case :ets.lookup(:inbound_profiles_cache, {:endpoint_config, endpoint_id}) do
        [{_, {config, custom_rules}}] ->
          parse_and_resolve(endpoint_id, config, custom_rules, packet, client_ip)

        [{_, {config, custom_rules, _legacy}}] ->
          parse_and_resolve(endpoint_id, config, custom_rules, packet, client_ip)

        _ ->
          :miss
      end
    else
      :miss
    end
  rescue
    _ -> :miss
  end

  defp parse_and_resolve(endpoint_id, config, custom_rules, packet, client_ip) do
    case Packet.parse(packet) do
      {:ok, query} ->
        case resolve_with_rule(
               endpoint_id,
               config,
               custom_rules,
               packet,
               query,
               client_ip
             ) do
          {:ok, resp} -> {:ok, resp}
          {:miss, _matched_rule} -> :miss
        end

      _ ->
        :miss
    end
  end

  @doc false
  def resolve_with_rule(
        profile_id,
        config,
        custom_rules,
        _packet,
        query,
        client_ip
      ) do
    enable_query_logging = config.enable_query_logging
    is_internal = Hermit.Vpn.SniProxy.IpResolver.internal_ip?(client_ip)

    # 0. AAAA Blocking (Filter IPv6)
    if query.qtype == :AAAA and Map.get(config, :block_ipv6, false) do
      resp = Packet.build_empty_response(query.id, query.query_record)

      :telemetry.execute(
        [:hermit, :dns, :query],
        %{duration: 0},
        %{
          profile_id: profile_id,
          config_id: config.id,
          client_ip: client_ip,
          domain: query.domain,
          qtype: query.qtype,
          status: "blocked",
          answer: "Empty (IPv6 Blocked)",
          resolver: "Local Filter",
          block_reason: "ipv6",
          enable_query_logging: enable_query_logging
        }
      )

      {:ok, resp}
    else
      # 1. Scoped cache lookup (O(1) ETS return without redundant checks)
      case Cache.lookup(profile_id, is_internal, query.domain, query.qtype) do
        {:ok, cached_packet, status, answer_log_info} ->
          <<_old_id::binary-size(2), rest_packet::binary>> = cached_packet
          resp_packet = query.id <> rest_packet

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
                String.contains?(answer_log_info, "Upstream Filter") -> "upstream_filter"
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
              client_ip: client_ip,
              domain: query.domain,
              qtype: query.qtype,
              status: status,
              answer: cached_answer,
              resolver: "Cache",
              block_reason: block_reason,
              enable_query_logging: enable_query_logging
            }
          )

          {:ok, resp_packet}

        :error ->
          # 2. Match custom rules once and reuse on :miss
          matched_rule = Rules.match(query.domain, custom_rules)

          {action, redirect_val, block_reason} =
            case matched_rule do
              {"block", nil, _} ->
                {"block", nil, "custom_rule"}

              {"route_tunnel", pair_id, _} ->
                if is_internal do
                  {nil, nil, nil}
                else
                  {"smart_route", pair_id, nil}
                end

              {act, val, _p_id} ->
                {act, val, nil}
            end

          # 3. Match Smart Routed Domains (SNI Proxy) if not matched by custom rules
          {action, redirect_val} =
            if is_nil(action) and not is_internal do
              case Hermit.Vpn.SniProxy.match(query.domain) do
                {:ok, smart_pair_id} ->
                  {"smart_route", smart_pair_id}

                :nomatch ->
                  {action, redirect_val}
              end
            else
              {action, redirect_val}
            end

          case action do
            "block" ->
              resp = Packet.build_nxdomain(query.id, query.query_record)

              answer_log_info =
                if block_reason == "custom_rule", do: "NXDOMAIN (Custom Rule)", else: "NXDOMAIN"

              Cache.store(
                profile_id,
                is_internal,
                query.domain,
                query.qtype,
                resp,
                "blocked",
                answer_log_info,
                5
              )

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: 0},
                %{
                  profile_id: profile_id,
                  config_id: config.id,
                  client_ip: client_ip,
                  domain: query.domain,
                  qtype: query.qtype,
                  status: "blocked",
                  answer: answer_log_info,
                  resolver: "Local Filter",
                  block_reason: block_reason,
                  enable_query_logging: enable_query_logging
                }
              )

              {:ok, resp}

            "redirect" when not is_nil(redirect_val) ->
              if query.qtype == :A do
                resp = Packet.build_a_response(query.id, query.query_record, redirect_val)

                Cache.store(
                  profile_id,
                  is_internal,
                  query.domain,
                  query.qtype,
                  resp,
                  "redirected",
                  redirect_val,
                  5
                )

                :telemetry.execute(
                  [:hermit, :dns, :query],
                  %{duration: 0},
                  %{
                    profile_id: profile_id,
                    config_id: config.id,
                    client_ip: client_ip,
                    domain: query.domain,
                    qtype: query.qtype,
                    status: "redirected",
                    answer: redirect_val,
                    resolver: "Local Rules",
                    enable_query_logging: enable_query_logging
                  }
                )

                {:ok, resp}
              else
                resp = Packet.build_nxdomain(query.id, query.query_record)

                Cache.store(
                  profile_id,
                  is_internal,
                  query.domain,
                  query.qtype,
                  resp,
                  "redirected",
                  "NXDOMAIN",
                  5
                )

                :telemetry.execute(
                  [:hermit, :dns, :query],
                  %{duration: 0},
                  %{
                    profile_id: profile_id,
                    config_id: config.id,
                    client_ip: client_ip,
                    domain: query.domain,
                    qtype: query.qtype,
                    status: "redirected",
                    answer: "NXDOMAIN",
                    resolver: "Local Rules",
                    enable_query_logging: enable_query_logging
                  }
                )

                {:ok, resp}
              end

            "smart_route" ->
              smart_ip = Hermit.Vpn.SniProxy.IpResolver.resolve_ip(client_ip)

              resp =
                if query.qtype == :A do
                  Packet.build_a_response(query.id, query.query_record, smart_ip)
                else
                  Packet.build_empty_response(query.id, query.query_record)
                end

              :telemetry.execute(
                [:hermit, :dns, :query],
                %{duration: 0},
                %{
                  profile_id: profile_id,
                  config_id: config.id,
                  client_ip: client_ip,
                  domain: query.domain,
                  qtype: query.qtype,
                  status: "smart_routed",
                  answer: smart_ip,
                  resolver: "Smart Route (#{redirect_val})",
                  enable_query_logging: enable_query_logging
                }
              )

              {:ok, resp}

            _ ->
              {:miss, matched_rule}
          end
      end
    end
  end
end
