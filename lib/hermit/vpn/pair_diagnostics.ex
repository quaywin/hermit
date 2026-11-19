defmodule Hermit.Vpn.PairDiagnostics do
  @moduledoc """
  Network diagnostics, endpoint DNS resolution, WireGuard handshake health checks,
  latency probing, and error formatting for VPN pairs.
  """
  require Logger

  def get_storage_base_path do
    config = Application.get_env(:hermit, :storage, [])
    Keyword.get(config, :base_path, "/app/storage")
  end

  def mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  def resolve_endpoint_in_config(nil), do: ""

  def resolve_endpoint_in_config(content) do
    Regex.replace(
      ~r/^\s*Endpoint\s*=\s*(\[[^\]]+\]|[^:\s]+)\s*:\s*(\d+)/mi,
      content,
      fn full_match, host, port ->
        case resolve_host(host) do
          {:ok, ip_str} -> "Endpoint = #{ip_str}:#{port}"
          _ -> full_match
        end
      end
    )
  end

  def resolve_host(host) do
    clean_host =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    charlist_host = String.to_charlist(clean_host)

    case :inet.getaddr(charlist_host, :inet) do
      {:ok, ip_tuple} ->
        {:ok, ip_tuple_to_string(ip_tuple)}

      _ ->
        case :inet.getaddr(charlist_host, :inet6) do
          {:ok, ip_tuple} -> {:ok, ip_tuple_to_string(ip_tuple)}
          error -> error
        end
    end
  end

  defp ip_tuple_to_string(ip_tuple) when tuple_size(ip_tuple) == 8 do
    ip_str = ip_tuple |> :inet.ntoa() |> List.to_string()
    "[#{ip_str}]"
  end

  defp ip_tuple_to_string(ip_tuple) do
    ip_tuple |> :inet.ntoa() |> List.to_string()
  end

  def diagnose_wg_handshake_failure(state) do
    config_content = state.wg_config_content || ""

    endpoint_host =
      case Regex.run(~r/^\s*Endpoint\s*=\s*(\[[^\]]+\]|[^:\s]+)\s*:\s*\d+/mi, config_content) do
        [_, host] ->
          host
          |> String.trim_leading("[")
          |> String.trim_trailing("]")

        _ ->
          nil
      end

    private_key =
      case Regex.run(~r/^\s*PrivateKey\s*=\s*([^\s#\n\r]+)/m, config_content) do
        [_, key] -> String.trim(key)
        _ -> nil
      end

    endpoint_ip =
      if endpoint_host do
        case resolve_host(endpoint_host) do
          {:ok, ip_str} -> ip_str
          _ -> endpoint_host
        end
      else
        nil
      end

    ping_ok =
      if endpoint_ip && not mock?() do
        try do
          case System.cmd("ping", ["-c", "1", "-W", "1", endpoint_ip], stderr_to_stdout: true) do
            {_, 0} -> true
            _ -> false
          end
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      else
        true
      end

    duplicate_pair_id =
      if private_key && private_key != "" do
        find_duplicate_private_key_pair(private_key, state.id)
      else
        nil
      end

    cond do
      duplicate_pair_id ->
        "Handshake Refused: Duplicate PrivateKey detected with active tunnel '#{duplicate_pair_id}'. VPN providers (NordVPN/Mullvad) drop duplicate key connections. Please use a unique PrivateKey for this profile."

      not ping_ok and endpoint_ip != nil ->
        "Endpoint Unreachable: Cannot connect to #{endpoint_host} (#{endpoint_ip}). Packet loss 100%. IP address may be blocked by ISP/firewall or server is offline. Try selecting a different server/region."

      true ->
        "WireGuard Handshake Refused: Server #{endpoint_ip || endpoint_host || "endpoint"} is reachable but rejected UDP handshake. Verify PrivateKey and PublicKey validity."
    end
  end

  defp find_duplicate_private_key_pair(private_key, current_pair_id) do
    import Ecto.Query

    try do
      from(p in Hermit.Vpn.VpnPair,
        where: p.pair_id != ^current_pair_id and p.wg_status in ["running", "starting"]
      )
      |> Hermit.Repo.all()
      |> Hermit.Repo.preload([:outbound_profile])
      |> Enum.find(fn pair ->
        cfg =
          cond do
            pair.outbound_config && map_size(pair.outbound_config) > 0 -> pair.outbound_config
            pair.outbound_profile -> pair.outbound_profile.config || %{}
            true -> %{}
          end

        content = Map.get(cfg, "wg_config") || Map.get(cfg, :wg_config) || ""

        case Regex.run(~r/^\s*PrivateKey\s*=\s*([^\s#\n\r]+)/m, content) do
          [_, key] -> String.trim(key) == private_key
          _ -> false
        end
      end)
      |> case do
        nil -> nil
        conflicting -> conflicting.pair_id
      end
    rescue
      _ -> nil
    end
  end

  def trigger_handshake(wg_name) do
    if not mock?() do
      Task.start(fn ->
        System.cmd("ip", [
          "netns",
          "exec",
          wg_name,
          "curl",
          "-s",
          "-o",
          "/dev/null",
          "--max-time",
          "1",
          "http://1.1.1.1"
        ])
      end)
    end
  end

  def netns_exists?(ns_name) do
    if mock?() do
      storage_dir =
        Path.join(get_storage_base_path(), String.replace(ns_name, "hermit_wg_", ""))

      File.exists?(storage_dir)
    else
      case System.cmd("ip", ["netns", "list"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            String.starts_with?(line, ns_name)
          end)

        _ ->
          false
      end
    end
  end

  def measure_ping(outbound_module, pair_id) do
    cond do
      mock?() ->
        :rand.uniform(60) + 20

      outbound_module == Hermit.Vpn.Outbound.Local ->
        :n_a

      true ->
        wg_name = "hermit_wg_#{pair_id}"

        case System.cmd(
               "ip",
               [
                 "netns",
                 "exec",
                 wg_name,
                 "curl",
                 "-o",
                 "/dev/null",
                 "-s",
                 "-w",
                 "%{time_connect}",
                 "--connect-timeout",
                 "2",
                 "http://1.1.1.1"
               ],
               stderr_to_stdout: false
             ) do
          {output, _exit_code} ->
            case Float.parse(String.trim(output)) do
              {val, _} when val > 0.0 -> round(val * 1000)
              _ -> :error
            end
        end
    end
  end

  def format_inbound_error(reason, "proxy") do
    "Proxy Inbound failed: #{inspect(reason)}"
  end

  def format_inbound_error(reason, _inbound_type) do
    str = inspect(reason)

    cond do
      String.contains?(str, "invalid key") or String.contains?(str, "API key") or
          String.contains?(str, "not valid") ->
        "Tailscale Auth Key is invalid or expired. Please update the key in Inbound Profiles."

      String.contains?(str, "tag not found") or
          (String.contains?(str, "tag:") and String.contains?(str, "not found")) ->
        "Tailscale ACL Tag not found. Please declare the tag in Tailscale ACL tagOwners."

      String.contains?(str, "node key has expired") or String.contains?(str, "key has expired") ->
        "Tailscale Node Key has expired. Please re-authenticate."

      String.contains?(str, "failed to connect to control server") ->
        "Cannot connect to Tailscale control plane. Check network or login server."

      match?({:tailscale_up_failed, {_code, output}} when is_binary(output), reason) ->
        {:tailscale_up_failed, {_code, output}} = reason
        lines = String.split(output, "\n", trim: true)

        err_line =
          Enum.find(Enum.reverse(lines), fn l -> not String.starts_with?(l, "Warning:") end)

        err_line || "Tailscale connection failed"

      true ->
        "Tailscale failed: #{inspect(reason)}"
    end
  end
end
