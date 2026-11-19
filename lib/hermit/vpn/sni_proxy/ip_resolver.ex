defmodule Hermit.Vpn.SniProxy.IpResolver do
  @moduledoc """
  Resolves the most appropriate IP address of Hermit to return in DNS answers
  for Smart Routed domains, depending on the client's network.
  """

  @cache_ttl_ms 5_000
  @routes_table :hermit_smart_routes

  @doc """
  Determines the best IP to return to the client for Smart DNS.
  """
  @spec resolve_ip(tuple() | String.t() | nil) :: String.t()
  def resolve_ip(client_ip) do
    # 1. Check explicit setting or env override
    case get_cached_override_ip() do
      {:ok, ip_str} ->
        ip_str

      :none ->
        auto_detect_ip(client_ip)
    end
  end

  @doc """
  Checks if an IP belongs to Hermit itself (internal container/host IP, netns veth, or Tailscale node IP).
  Used to prevent DNS and SNI proxy routing loops.
  """
  @spec internal_ip?(tuple() | String.t() | nil) :: boolean()
  def internal_ip?(ip) do
    case parse_ip(ip) do
      {10, 200, _, _} ->
        true

      {10, 251, _, _} ->
        true

      parsed when is_tuple(parsed) ->
        internal_set = get_cached_internal_ips()
        MapSet.member?(internal_set, parsed)

      _ ->
        false
    end
  end

  @doc """
  Clears in-memory ETS caches for IP resolution.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.info(@routes_table) != :undefined do
      :ets.delete(@routes_table, {:__cache__, :internal_ips})
      :ets.delete(@routes_table, {:__cache__, :override_ip})
      :ets.delete(@routes_table, {:__cache__, :interfaces})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Retrieves Tailscale IPs belonging to active tunnel nodes to prevent them from routing to themselves.
  """
  @spec get_all_node_ips() :: [tuple()]
  def get_all_node_ips do
    pair_ips =
      try do
        case Code.ensure_loaded(Hermit.Vpn.PairWorker) do
          {:module, _} ->
            Hermit.Vpn.PairWorker.list_pairs()
            |> Enum.flat_map(fn pair ->
              metrics = Map.get(pair, :metrics) || %{}
              Map.get(metrics, :ts_ips, [])
            end)
            |> Enum.map(&parse_ip/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
        _kind, _reason -> []
      end

    dns_worker_ips =
      try do
        case Code.ensure_loaded(Hermit.Vpn.DnsWorker) do
          {:module, _} ->
            Hermit.Repo.all(Hermit.Vpn.DnsEndpoint)
            |> Enum.flat_map(fn ep ->
              case Hermit.Vpn.DnsWorker.get_status(ep.id) do
                {:running, ts_ip, _} when is_binary(ts_ip) and ts_ip != "" ->
                  [parse_ip(ts_ip)]

                _ ->
                  []
              end
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
        _kind, _reason -> []
      end

    Enum.uniq(pair_ips ++ dns_worker_ips)
  end

  defp get_cached_internal_ips do
    now = System.monotonic_time(:millisecond)

    case lookup_cache(:internal_ips, now) do
      {:ok, set} ->
        set

      :miss ->
        set =
          (get_cached_ipv4_interfaces(now) ++ get_all_node_ips())
          |> MapSet.new()

        store_cache(:internal_ips, set, now + @cache_ttl_ms)
        set
    end
  end

  defp get_cached_override_ip do
    now = System.monotonic_time(:millisecond)

    case lookup_cache(:override_ip, now) do
      {:ok, val} ->
        val

      :miss ->
        val = get_override_ip()
        store_cache(:override_ip, val, now + @cache_ttl_ms)
        val
    end
  end

  defp get_cached_ipv4_interfaces(now \\ System.monotonic_time(:millisecond)) do
    case lookup_cache(:interfaces, now) do
      {:ok, ifaces} ->
        ifaces

      :miss ->
        ifaces = get_ipv4_interfaces()
        store_cache(:interfaces, ifaces, now + @cache_ttl_ms)
        ifaces
    end
  end

  defp lookup_cache(key, now) do
    case :ets.info(@routes_table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@routes_table, {:__cache__, key}) do
          [{{:__cache__, ^key}, val, expires_at}] when expires_at > now ->
            {:ok, val}

          _ ->
            :miss
        end
    end
  rescue
    _ -> :miss
  end

  defp store_cache(key, val, expires_at) do
    if :ets.info(@routes_table) != :undefined do
      :ets.insert(@routes_table, {{:__cache__, key}, val, expires_at})
    end
  rescue
    _ -> :ok
  end

  defp get_override_ip do
    env_ip = System.get_env("SMART_DNS_IP") || System.get_env("HERMIT_SMART_DNS_IP")

    cond do
      is_binary(env_ip) and String.trim(env_ip) != "" ->
        {:ok, String.trim(env_ip)}

      true ->
        case Code.ensure_loaded(Hermit.Vpn.Setting) do
          {:module, _} ->
            try do
              case Hermit.Vpn.Setting.get_value("smart_dns_ip") do
                val when is_binary(val) and val != "" -> {:ok, String.trim(val)}
                _ -> :none
              end
            rescue
              _ -> :none
            end

          _ ->
            :none
        end
    end
  end

  defp auto_detect_ip(client_ip) do
    parsed_client = parse_ip(client_ip)
    all_ifaces = get_cached_ipv4_interfaces()

    cond do
      # If client is connecting from Tailscale (100.64.0.0/10)
      parsed_client && in_tailscale_range?(parsed_client) ->
        case find_tailscale_ip(all_ifaces) do
          {:ok, ts_ip} ->
            ts_ip

          :none ->
            case Enum.find(get_all_node_ips(), &in_tailscale_range?/1) do
              nil -> fallback_ip(all_ifaces)
              ts_tuple -> ip_to_string(ts_tuple)
            end
        end

      # Find an interface in the same subnet
      parsed_client ->
        case find_same_subnet_ip(parsed_client, all_ifaces) do
          {:ok, same_sub_ip} -> same_sub_ip
          :none -> fallback_ip(all_ifaces)
        end

      true ->
        fallback_ip(all_ifaces)
    end
  end

  defp parse_ip({:doh, ip, _}), do: parse_ip(ip)
  defp parse_ip({:dot, ip, _}), do: parse_ip(ip)
  defp parse_ip({:tcp, ip, _}), do: parse_ip(ip)
  defp parse_ip({_, _, _, _} = ip), do: ip

  defp parse_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, {_, _, _, _} = ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil

  defp in_tailscale_range?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp in_tailscale_range?(_), do: false

  defp get_ipv4_interfaces do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        Enum.flat_map(ifaces, fn {_name, opts} ->
          addrs = Keyword.get_values(opts, :addr)
          flags = Keyword.get(opts, :flags, [])

          if :running in flags and :loopback not in flags do
            Enum.filter(addrs, fn
              {_, _, _, _} -> true
              _ -> false
            end)
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp find_tailscale_ip(ifaces) do
    case Enum.find(ifaces, &in_tailscale_range?/1) do
      nil -> :none
      ip -> {:ok, ip_to_string(ip)}
    end
  end

  defp find_same_subnet_ip({a, b, c, _}, ifaces) do
    case Enum.find(ifaces, fn {ia, ib, ic, _} -> ia == a and ib == b and ic == c end) do
      nil -> :none
      ip -> {:ok, ip_to_string(ip)}
    end
  end

  defp fallback_ip([first_ip | _]), do: ip_to_string(first_ip)
  defp fallback_ip([]), do: "127.0.0.1"

  defp ip_to_string(ip_tuple) do
    ip_tuple |> :inet.ntoa() |> List.to_string()
  end
end
