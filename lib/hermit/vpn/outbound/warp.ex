defmodule Hermit.Vpn.Outbound.Warp do
  @moduledoc """
  Cloudflare WARP outbound gateway with automatic free WireGuard credential registration,
  curated Public NAT64 regional endpoints, and transparent IPv6 bridge support on IPv4-only hosts.
  """
  @behaviour Hermit.Vpn.Outbound
  require Logger

  alias Hermit.Vpn.Outbound.WarpBridge
  alias Hermit.Vpn.Outbound.WireGuard

  @default_warp_ipv4 "162.159.192.1"
  @default_warp_port 2408
  @default_peer_public_key "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  @cf_reg_url "https://api.cloudflareclient.com/v0a2158/reg"

  @regions [
    %{id: "auto", label: "Auto (Nearest)", nat64_prefix: nil},
    %{
      id: "us_fremont",
      label: "US - California (Fremont)",
      nat64_prefix: "2602:fc59:b0:64::/96"
    },
    %{
      id: "us_illinois",
      label: "US - Midwest (Illinois)",
      nat64_prefix: "2602:fc59:11:64::/96"
    },
    %{
      id: "nl_amsterdam",
      label: "Netherlands (Amsterdam)",
      nat64_prefix: "2a00:1098:2b::1:0:0/96"
    },
    %{
      id: "fi_helsinki",
      label: "Finland (Helsinki)",
      nat64_prefix: "2a01:4f9:c010:3f02:64::/96"
    },
    %{id: "custom", label: "Custom NAT64 Prefix", nat64_prefix: nil}
  ]

  @region_ids Enum.map(@regions, & &1.id)

  @doc """
  Returns the full list of supported Cloudflare WARP region descriptors.
  """
  def regions, do: @regions

  @doc """
  Returns the list of valid WARP region identifiers.
  """
  def valid_region_ids, do: @region_ids

  @doc """
  Returns `{label, id}` options for HTML select controls.
  """
  def region_options do
    Enum.map(@regions, fn r -> {r.label, r.id} end)
  end

  @doc """
  Returns a human-readable label for a WARP outbound config map or region ID.
  """
  def region_label(nil), do: region_label("auto")

  def region_label(config) when is_map(config) do
    region = Map.get(config, "region") || Map.get(config, :region) || "auto"

    if region == "custom" do
      prefix =
        Map.get(config, "custom_nat64_prefix") || Map.get(config, :custom_nat64_prefix) || ""

      trimmed = String.trim(to_string(prefix))
      if trimmed == "", do: "Custom NAT64 Prefix", else: "Custom (#{trimmed})"
    else
      region_label(region)
    end
  end

  def region_label(region_id) when is_binary(region_id) do
    case Enum.find(@regions, &(&1.id == region_id)) do
      %{label: label} -> label
      nil -> region_id
    end
  end

  @doc """
  Validates an IPv6 NAT64 `/96` prefix (with or without the trailing `/96`).
  Returns `{:ok, normalized_prefix}` or `{:error, message}`.
  """
  def validate_nat64_prefix(nil), do: {:error, "Custom NAT64 prefix is required"}

  def validate_nat64_prefix(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    cond do
      trimmed == "" ->
        {:error, "Custom NAT64 prefix is required"}

      String.contains?(trimmed, "/") and not String.ends_with?(trimmed, "/96") ->
        {:error, "NAT64 prefix must use /96 prefix length (e.g. 2602:fc59:b0:64::/96)"}

      true ->
        base = String.trim_trailing(trimmed, "/96")

        case :inet.parse_ipv6strict_address(String.to_charlist(base)) do
          {:ok, {a, b, c, d, e, f, 0, 0}} ->
            normalized = {a, b, c, d, e, f, 0, 0} |> :inet.ntoa() |> List.to_string()
            {:ok, "#{normalized}/96"}

          {:ok, _non_zero_host_bits} ->
            {:error, "NAT64 /96 prefix must have zero host bits (end with ::/96 or :0:0/96)"}

          {:error, _} ->
            {:error, "NAT64 prefix must be a valid IPv6 /96 prefix (e.g. 2602:fc59:b0:64::/96)"}
        end
    end
  end

  def validate_nat64_prefix(_), do: {:error, "Custom NAT64 prefix must be a string"}

  @doc """
  Synthesizes a bracketed `[IPv6]:port` WireGuard endpoint by embedding an IPv4 address
  into the low 32 bits of an RFC 6052 `/96` NAT64 prefix.
  """
  def synthesize_nat64_endpoint(prefix, ipv4 \\ @default_warp_ipv4, port \\ @default_warp_port) do
    with {:ok, normalized_prefix} <- validate_nat64_prefix(prefix),
         base = String.trim_trailing(normalized_prefix, "/96"),
         {:ok, {a, b, c, d, e, f, 0, 0}} <-
           :inet.parse_ipv6strict_address(String.to_charlist(base)),
         {:ok, {o1, o2, o3, o4}} <- :inet.parse_ipv4strict_address(String.to_charlist(ipv4)) do
      g = Bitwise.bsl(o1, 8) + o2
      h = Bitwise.bsl(o3, 8) + o4
      synth = {a, b, c, d, e, f, g, h} |> :inet.ntoa() |> List.to_string()
      {:ok, "[#{synth}]:#{port}"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Invalid NAT64 prefix or IPv4 address"}
    end
  end

  @doc """
  Generates an X25519 WireGuard keypair as `{private_key_b64, public_key_b64}`.
  """
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
    {Base.encode64(priv), Base.encode64(pub)}
  end

  @doc """
  Loads persisted WARP credentials from `storage_dir/warp_account.json` or registers
  a new free WARP account via Cloudflare's client registration API and saves it.
  """
  def ensure_account(storage_dir, opts \\ []) do
    account_path = Path.join(storage_dir, "warp_account.json")

    case read_valid_account(account_path) do
      {:ok, account} ->
        {:ok, account}

      :missing_or_invalid ->
        with {:ok, account} <- register_or_mock_account(opts) do
          File.mkdir_p!(storage_dir)
          File.write!(account_path, Jason.encode!(account, pretty: true))
          File.chmod!(account_path, 0o600)
          {:ok, account}
        end
    end
  end

  @doc """
  Registers a new free Cloudflare WARP WireGuard device via Cloudflare's client API.
  """
  def register_account(opts \\ []) do
    {priv_b64, pub_b64} = generate_keypair()

    tos =
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()

    headers = [
      {"content-type", "application/json; charset=UTF-8"},
      {"user-agent", "okhttp/3.12.1"}
    ]

    reg_payload = %{
      "key" => pub_b64,
      "install_id" => "",
      "fcm_token" => "",
      "tos" => tos,
      "model" => "PC",
      "serial_number" => "",
      "locale" => "en_US"
    }

    req_opts = Keyword.get(opts, :req_options, [])
    post_fn = Keyword.get(opts, :post_fn, &Req.post/2)
    patch_fn = Keyword.get(opts, :patch_fn, &Req.patch/2)

    case post_fn.(
           @cf_reg_url,
           [json: reg_payload, headers: headers, receive_timeout: 15_000] ++ req_opts
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] and is_map(body) ->
        with {:ok, id} <- fetch_non_empty(body, ["id"]),
             {:ok, token} <- fetch_non_empty(body, ["token"]),
             {:ok, v4} <- fetch_non_empty(body, ["config", "interface", "addresses", "v4"]),
             {:ok, v6} <- fetch_non_empty(body, ["config", "interface", "addresses", "v6"]) do
          peer_pub =
            case get_in(body, ["config", "peers"]) do
              [%{"public_key" => pk} | _] when is_binary(pk) and pk != "" -> pk
              _ -> @default_peer_public_key
            end

          _ =
            patch_fn.(
              "#{@cf_reg_url}/#{id}",
              [
                json: %{"warp_enabled" => true},
                headers: [{"authorization", "Bearer #{token}"} | headers],
                receive_timeout: 10_000
              ] ++ req_opts
            )

          {:ok,
           %{
             "id" => id,
             "private_key" => priv_b64,
             "public_key" => pub_b64,
             "v4" => v4,
             "v6" => v6,
             "peer_public_key" => peer_pub
           }}
        else
          _ -> {:error, {:warp_registration_invalid_response, body}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:warp_registration_http_error, status, body}}

      {:error, reason} ->
        {:error, {:warp_registration_request_failed, reason}}
    end
  end

  @doc """
  Renders a complete WireGuard configuration payload for a WARP account, endpoint, and MTU.
  """
  def build_wg_config(account, endpoint, mtu) when is_map(account) do
    priv = Map.fetch!(account, "private_key")
    v4 = Map.fetch!(account, "v4")
    v6 = Map.fetch!(account, "v6")
    peer_pub = Map.get(account, "peer_public_key") || @default_peer_public_key

    """
    [Interface]
    PrivateKey = #{priv}
    Address = #{v4}/32, #{v6}/128
    DNS = 1.1.1.1
    MTU = #{mtu}

    [Peer]
    PublicKey = #{peer_pub}
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = #{endpoint}
    PersistentKeepalive = 25
    """
  end

  @doc """
  Returns true if the host has working default IPv6 connectivity.
  """
  def host_has_ipv6? do
    if mock?() do
      false
    else
      case System.cmd("ip", ["-6", "route", "show", "default"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.trim(out) != "" do
            case System.cmd("ping", ["-6", "-c", "1", "-W", "2", "2606:4700:4700::1111"],
                   stderr_to_stdout: true
                 ) do
              {_, 0} -> true
              _ -> false
            end
          else
            false
          end

        _ ->
          false
      end
    end
  rescue
    _ -> false
  end

  @impl true
  def bootstrap(pair_id, storage_dir, config) do
    with {:ok, {endpoint, mtu, needs_ipv6?}} <- resolve_endpoint_and_mtu(config),
         :ok <- File.mkdir_p(storage_dir),
         {:ok, account} <- ensure_account(storage_dir) do
      wg_conf = build_wg_config(account, endpoint, mtu)
      wg_config_path = Path.join(storage_dir, "wg0.conf")
      File.write!(wg_config_path, wg_conf)
      File.chmod!(wg_config_path, 0o600)

      wg_opts = %{
        "wg_config" => wg_conf,
        "block_ipv6" => Map.get(config, "block_ipv6") || Map.get(config, :block_ipv6) || false,
        "use_tailscale_dns" =>
          Map.get(config, "use_tailscale_dns") || Map.get(config, :use_tailscale_dns) || false
      }

      if needs_ipv6? and not host_has_ipv6?() do
        case WarpBridge.ensure_bridge(pair_id) do
          {:ok, bridge_ns} ->
            case WireGuard.bootstrap(
                   pair_id,
                   storage_dir,
                   Map.put(wg_opts, "create_in_netns", bridge_ns)
                 ) do
              {:ok, iface} ->
                {:ok, iface}

              {:error, reason} ->
                WarpBridge.release_bridge(pair_id)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      else
        WireGuard.bootstrap(pair_id, storage_dir, wg_opts)
      end
    end
  end

  @impl true
  def cleanup(pair_id, storage_dir) do
    WireGuard.cleanup(pair_id, storage_dir)
    WarpBridge.release_bridge(pair_id)
    :ok
  end

  @impl true
  def get_status(pair_id, storage_dir), do: WireGuard.get_status(pair_id, storage_dir)

  @impl true
  def get_metrics(pair_id, storage_dir), do: WireGuard.get_metrics(pair_id, storage_dir)

  # --- Private Helpers ---

  defp resolve_endpoint_and_mtu(config) when is_map(config) do
    region = Map.get(config, "region") || Map.get(config, :region) || "auto"

    cond do
      region == "auto" ->
        {:ok, {"#{@default_warp_ipv4}:#{@default_warp_port}", "1380", false}}

      region == "custom" ->
        prefix =
          Map.get(config, "custom_nat64_prefix") || Map.get(config, :custom_nat64_prefix)

        with {:ok, endpoint} <- synthesize_nat64_endpoint(prefix) do
          {:ok, {endpoint, "1280", true}}
        end

      true ->
        case Enum.find(@regions, &(&1.id == region)) do
          %{nat64_prefix: prefix} when is_binary(prefix) ->
            with {:ok, endpoint} <- synthesize_nat64_endpoint(prefix) do
              {:ok, {endpoint, "1280", true}}
            end

          _ ->
            {:error, {:unknown_warp_region, region}}
        end
    end
  end

  defp resolve_endpoint_and_mtu(_), do: resolve_endpoint_and_mtu(%{})

  defp register_or_mock_account(opts) do
    if mock?() and not Keyword.has_key?(opts, :post_fn) do
      {priv_b64, pub_b64} = generate_keypair()

      {:ok,
       %{
         "id" => "mock-warp-#{System.unique_integer([:positive])}",
         "private_key" => priv_b64,
         "public_key" => pub_b64,
         "v4" => "172.16.0.2",
         "v6" => "2606:4700:110:8000::2",
         "peer_public_key" => @default_peer_public_key
       }}
    else
      register_account(opts)
    end
  end

  defp read_valid_account(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = data} ->
            required = ["private_key", "v4", "v6", "peer_public_key"]

            if Enum.all?(required, fn k -> is_binary(data[k]) and data[k] != "" end) do
              {:ok, data}
            else
              :missing_or_invalid
            end

          _ ->
            :missing_or_invalid
        end

      _ ->
        :missing_or_invalid
    end
  end

  defp fetch_non_empty(map, path) do
    case get_in(map, path) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> :error
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
