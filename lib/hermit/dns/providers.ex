defmodule Hermit.Dns.Providers do
  @moduledoc """
  Catalog of cloud DNS filtering providers and preset resolvers
  (Control D, Control D Community Lists, AdGuard DNS, Cloudflare, Quad9, and Custom).
  """

  @default_upstream "76.76.2.2, 76.76.10.2"
  @default_clean_bypass "1.1.1.1, 76.76.2.0"

  @tailscale_doh_prefixes [
    "https://dns.nextdns.io/",
    "https://dns.controld.com/",
    "https://cloudflare-dns.com/dns-query",
    "https://security.cloudflare-dns.com/dns-query",
    "https://family.cloudflare-dns.com/dns-query",
    "https://dns.quad9.net/dns-query",
    "https://dns11.quad9.net/dns-query",
    "https://dns.adguard-dns.com/dns-query",
    "https://family.adguard-dns.com/dns-query",
    "https://unfiltered.adguard-dns.com/dns-query",
    "https://dns.google/dns-query",
    "https://doh.mullvad.net/dns-query"
  ]

  @providers [
    %{
      id: "controld",
      name: "Control D",
      protocols: [:udp, :doh],
      presets: [
        %{
          id: "p2",
          label: "Ads & Tracking (Recommended)",
          udp: "76.76.2.2, 76.76.10.2",
          doh: "https://freedns.controld.com/p2"
        },
        %{
          id: "p1",
          label: "Malware Protection",
          udp: "76.76.2.1, 76.76.10.1",
          doh: "https://freedns.controld.com/p1"
        },
        %{
          id: "p3",
          label: "Social Media + Ads",
          udp: "76.76.2.3, 76.76.10.3",
          doh: "https://freedns.controld.com/p3"
        },
        %{
          id: "family",
          label: "Family Friendly",
          udp: "76.76.2.4, 76.76.10.4",
          doh: "https://freedns.controld.com/family"
        },
        %{
          id: "uncensored",
          label: "Uncensored",
          udp: "76.76.2.5, 76.76.10.5",
          doh: "https://freedns.controld.com/uncensored"
        },
        %{
          id: "p0",
          label: "Unfiltered",
          udp: "76.76.2.0, 76.76.10.0",
          doh: "https://freedns.controld.com/p0"
        }
      ]
    },
    %{
      id: "controld_community",
      name: "Control D — Community Lists",
      protocols: [:doh],
      presets: [
        %{id: "x-oisd", label: "OISD Full", doh: "https://freedns.controld.com/x-oisd"},
        %{
          id: "x-oisd-basic",
          label: "OISD Basic",
          doh: "https://freedns.controld.com/x-oisd-basic"
        },
        %{
          id: "x-hagezi-light",
          label: "HaGeZi Light",
          doh: "https://freedns.controld.com/x-hagezi-light"
        },
        %{
          id: "x-hagezi-normal",
          label: "HaGeZi Normal",
          doh: "https://freedns.controld.com/x-hagezi-normal"
        },
        %{
          id: "x-hagezi-pro",
          label: "HaGeZi Pro",
          doh: "https://freedns.controld.com/x-hagezi-pro"
        },
        %{
          id: "x-hagezi-proplus",
          label: "HaGeZi Pro++",
          doh: "https://freedns.controld.com/x-hagezi-proplus"
        },
        %{
          id: "x-hagezi-ultimate",
          label: "HaGeZi Ultimate",
          doh: "https://freedns.controld.com/x-hagezi-ultimate"
        },
        %{
          id: "x-hagezi-tif",
          label: "HaGeZi Threat Intelligence (TIF)",
          doh: "https://freedns.controld.com/x-hagezi-tif"
        },
        %{
          id: "x-1hosts-mini",
          label: "1Hosts Mini",
          doh: "https://freedns.controld.com/x-1hosts-mini"
        },
        %{
          id: "x-1hosts-lite",
          label: "1Hosts Lite",
          doh: "https://freedns.controld.com/x-1hosts-lite"
        },
        %{
          id: "x-1hosts-pro",
          label: "1Hosts Pro",
          doh: "https://freedns.controld.com/x-1hosts-pro"
        },
        %{
          id: "x-1hosts-xtra",
          label: "1Hosts Xtra",
          doh: "https://freedns.controld.com/x-1hosts-xtra"
        }
      ]
    },
    %{
      id: "adguard",
      name: "AdGuard DNS",
      protocols: [:udp, :doh],
      presets: [
        %{
          id: "default",
          label: "Default (Ads & Trackers)",
          udp: "94.140.14.14, 94.140.15.15",
          doh: "https://dns.adguard-dns.com/dns-query"
        },
        %{
          id: "family",
          label: "Family Protection",
          udp: "94.140.14.15, 94.140.15.16",
          doh: "https://family.adguard-dns.com/dns-query"
        },
        %{
          id: "unfiltered",
          label: "Non-Filtering",
          udp: "94.140.14.140, 94.140.14.141",
          doh: "https://unfiltered.adguard-dns.com/dns-query"
        }
      ]
    },
    %{
      id: "cloudflare",
      name: "Cloudflare",
      protocols: [:udp, :doh],
      presets: [
        %{
          id: "standard",
          label: "Standard (1.1.1.1)",
          udp: "1.1.1.1, 1.0.0.1",
          doh: "https://cloudflare-dns.com/dns-query"
        },
        %{
          id: "malware",
          label: "Malware Blocking (1.1.1.2)",
          udp: "1.1.1.2, 1.0.0.2",
          doh: "https://security.cloudflare-dns.com/dns-query"
        },
        %{
          id: "family",
          label: "Malware + Adult (1.1.1.3)",
          udp: "1.1.1.3, 1.0.0.3",
          doh: "https://family.cloudflare-dns.com/dns-query"
        }
      ]
    },
    %{
      id: "quad9",
      name: "Quad9",
      protocols: [:udp, :doh],
      presets: [
        %{
          id: "recommended",
          label: "Malware + DNSSEC (9.9.9.9)",
          udp: "9.9.9.9, 149.112.112.112",
          doh: "https://dns.quad9.net/dns-query"
        },
        %{
          id: "ecs",
          label: "Malware + ECS (9.9.9.11)",
          udp: "9.9.9.11, 149.112.112.11",
          doh: "https://dns11.quad9.net/dns-query"
        }
      ]
    },
    %{
      id: "custom",
      name: "Custom (Control D / NextDNS / RethinkDNS / IP)",
      protocols: [],
      presets: []
    }
  ]

  @spec all() :: [map()]
  def all, do: @providers

  @spec default_upstream() :: String.t()
  def default_upstream, do: @default_upstream

  @spec clean_bypass_upstreams() :: String.t()
  def clean_bypass_upstreams do
    Application.get_env(:hermit, :clean_bypass_upstreams, @default_clean_bypass)
  end

  @spec get_provider(String.t() | nil) :: map() | nil
  def get_provider(provider_id) do
    Enum.find(@providers, &(&1.id == provider_id))
  end

  @spec presets_for(String.t() | nil) :: [map()]
  def presets_for(provider_id) do
    case get_provider(provider_id) do
      %{presets: presets} -> presets
      _ -> []
    end
  end

  @spec default_preset_id(String.t() | nil) :: String.t() | nil
  def default_preset_id(provider_id) do
    case presets_for(provider_id) do
      [first | _] -> first.id
      [] -> nil
    end
  end

  @spec default_protocol_for(String.t() | nil) :: :udp | :doh
  def default_protocol_for(provider_id) do
    case get_provider(provider_id) do
      %{protocols: [first | _]} -> first
      _ -> :doh
    end
  end

  @spec supports_protocol_toggle?(String.t() | nil) :: boolean()
  def supports_protocol_toggle?(provider_id) do
    case get_provider(provider_id) do
      %{protocols: protocols} -> length(protocols) > 1
      _ -> false
    end
  end

  @spec resolve_upstream(String.t() | nil, String.t() | nil, :udp | :doh) :: String.t() | nil
  def resolve_upstream(provider_id, preset_id, protocol) do
    with %{presets: presets} <- get_provider(provider_id),
         preset when not is_nil(preset) <- Enum.find(presets, &(&1.id == preset_id)) do
      Map.get(preset, protocol) || Map.get(preset, :doh) || Map.get(preset, :udp)
    else
      _ -> nil
    end
  end

  @spec detect(String.t() | nil) :: {String.t(), String.t() | nil, :udp | :doh}
  def detect(nil), do: {"custom", nil, :doh}

  def detect(upstream_str) when is_binary(upstream_str) do
    tokens = normalize_tokens(upstream_str)

    match =
      Enum.find_value(@providers, fn provider ->
        Enum.find_value(provider.presets, fn preset ->
          cond do
            Map.has_key?(preset, :udp) and normalize_tokens(preset.udp) == tokens ->
              {provider.id, preset.id, :udp}

            Map.has_key?(preset, :doh) and normalize_tokens(preset.doh) == tokens ->
              {provider.id, preset.id, :doh}

            true ->
              nil
          end
        end)
      end)

    case match do
      nil ->
        proto =
          if Enum.any?(tokens, &String.starts_with?(&1, "https://")), do: :doh, else: :udp

        {"custom", nil, proto}

      found ->
        found
    end
  end

  @doc """
  Resolves an upstream DNS string into resolvers compatible with Tailscale
  Global Nameservers (`/dns/configuration`), or `{:fallback_global, reason}`
  when the upstream requires Hermit to intercept traffic globally.
  """
  @spec tailscale_global_resolvers(String.t() | nil) ::
          {:ok, [String.t()]} | {:fallback_global, atom()}
  def tailscale_global_resolvers(nil), do: {:fallback_global, :empty_upstream}

  def tailscale_global_resolvers(upstream_str) when is_binary(upstream_str) do
    trimmed = String.trim(upstream_str)

    if trimmed == "" do
      {:fallback_global, :empty_upstream}
    else
      case detect(trimmed) do
        {provider_id, preset_id, _proto}
        when provider_id != "custom" and not is_nil(preset_id) ->
          with %{presets: presets} <- get_provider(provider_id),
               preset when not is_nil(preset) <- Enum.find(presets, &(&1.id == preset_id)),
               udp when is_binary(udp) and udp != "" <- Map.get(preset, :udp) do
            {:ok, udp |> normalize_tokens() |> dedupe_single_instance_providers()}
          else
            _ -> {:fallback_global, :unsupported_doh}
          end

        _custom ->
          tokens = normalize_tokens(trimmed)
          parsed = Enum.map(tokens, &parse_tailscale_compatible_resolver/1)

          if parsed != [] and Enum.all?(parsed, &match?({:ok, _}, &1)) do
            resolvers =
              parsed
              |> Enum.map(fn {:ok, val} -> val end)
              |> Enum.uniq()
              |> dedupe_single_instance_providers()

            {:ok, resolvers}
          else
            {:fallback_global, :unsupported_upstream}
          end
      end
    end
  end

  defp dedupe_single_instance_providers(resolvers) do
    {result, _seen} =
      Enum.reduce(resolvers, {[], MapSet.new()}, fn resolver, {acc, seen} ->
        case provider_singleton_key(resolver) do
          nil ->
            {[resolver | acc], seen}

          key ->
            if MapSet.member?(seen, key) do
              {acc, seen}
            else
              {[resolver | acc], MapSet.put(seen, key)}
            end
        end
      end)

    Enum.reverse(result)
  end

  defp provider_singleton_key(resolver) do
    cond do
      String.starts_with?(resolver, "https://dns.controld.com/") or
        String.starts_with?(resolver, "76.76.2.") or
          String.starts_with?(resolver, "76.76.10.") ->
        :controld

      String.starts_with?(resolver, "https://dns.nextdns.io/") or
        String.starts_with?(resolver, "45.90.28.") or
          String.starts_with?(resolver, "45.90.30.") ->
        :nextdns

      true ->
        nil
    end
  end

  defp parse_tailscale_compatible_resolver(token) do
    cond do
      match?({:ok, _}, :inet.parse_address(String.to_charlist(token))) ->
        {:ok, token}

      String.ends_with?(token, ":53") ->
        case Regex.run(~r/^\[([^\]]+)\]:53$/, token) do
          [_, ip_str] ->
            if match?({:ok, _}, :inet.parse_address(String.to_charlist(ip_str))),
              do: {:ok, ip_str},
              else: :error

          nil ->
            case String.split(token, ":") do
              [ip_str, "53"] ->
                if match?({:ok, _}, :inet.parse_address(String.to_charlist(ip_str))),
                  do: {:ok, ip_str},
                  else: :error

              _ ->
                :error
            end
        end

      Enum.any?(@tailscale_doh_prefixes, &String.starts_with?(token, &1)) ->
        {:ok, token}

      true ->
        :error
    end
  end

  @doc """
  Returns all IP addresses used by built-in provider presets for Tailscale Global Nameservers.
  Used to cleanly strip previously synced provider IPs when switching from Split DNS to Global DNS.
  """
  @spec all_preset_global_resolvers() :: [String.t()]
  def all_preset_global_resolvers do
    @providers
    |> Enum.flat_map(& &1.presets)
    |> Enum.flat_map(fn preset ->
      case Map.get(preset, :udp) do
        udp when is_binary(udp) and udp != "" -> normalize_tokens(udp)
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp normalize_tokens(str) do
    str
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
  end
end
