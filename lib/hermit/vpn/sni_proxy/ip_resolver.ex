defmodule Hermit.Vpn.SniProxy.IpResolver do
  @moduledoc """
  Resolves the most appropriate IP address of Hermit to return in DNS answers
  for Smart Routed domains, depending on the client's network.
  """

  @doc """
  Determines the best IP to return to the client for Smart DNS.
  """
  @spec resolve_ip(tuple() | String.t() | nil) :: String.t()
  def resolve_ip(client_ip) do
    # 1. Check explicit setting or env override
    case get_override_ip() do
      {:ok, ip_str} ->
        ip_str

      :none ->
        auto_detect_ip(client_ip)
    end
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
    all_ifaces = get_ipv4_interfaces()

    cond do
      # If client is connecting from Tailscale (100.64.0.0/10)
      parsed_client && in_tailscale_range?(parsed_client) ->
        case find_tailscale_ip(all_ifaces) do
          {:ok, ts_ip} -> ts_ip
          :none -> fallback_ip(all_ifaces)
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
