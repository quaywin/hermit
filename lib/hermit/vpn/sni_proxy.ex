defmodule Hermit.Vpn.SniProxy do
  @moduledoc """
  Manages Smart DNS / SNI Proxy routing rules and provides
  route matching for incoming TLS (HTTPS) and HTTP connections.
  """

  @table :hermit_smart_routes

  @doc """
  Initializes the ETS table for smart domain routes.
  Called on application startup.
  """
  def init_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Registers a list of domains for a specific tunnel (pair_id).
  """
  @spec register_routes(String.t(), [String.t()]) :: :ok
  def register_routes(pair_id, domains) when is_binary(pair_id) and is_list(domains) do
    init_table()

    # First clean up old domain routes for this pair without clearing port cache
    unregister_routes_for_pair(pair_id)

    Enum.each(domains, fn domain ->
      norm = domain |> String.trim() |> String.downcase()

      if norm != "" do
        :ets.insert(@table, {norm, pair_id})

        # Clear any existing upstream cache on Hermit DNS for this domain/wildcard
        Hermit.Dns.Cache.delete_domain(norm)

        # If it's a wildcard like *.domain.com, also match domain.com itself
        if String.starts_with?(norm, "*.") do
          base = String.slice(norm, 2..-1//1)
          :ets.insert(@table, {base, pair_id})
          Hermit.Dns.Cache.delete_domain(base)
        end
      end
    end)

    Hermit.Vpn.SniProxy.IpResolver.clear_cache()
    :ok
  end

  @doc """
  Unregisters all routes belonging to a pair_id.
  """
  @spec unregister_pair(String.t()) :: :ok
  def unregister_pair(pair_id) when is_binary(pair_id) do
    init_table()

    unregister_routes_for_pair(pair_id)
    :ets.delete(@table, {:ports, pair_id})
    Hermit.Vpn.SniProxy.IpResolver.clear_cache()
    :ok
  end

  defp unregister_routes_for_pair(pair_id) do
    matches =
      :ets.select(@table, [
        {{:"$1", :"$2"}, [{:==, :"$2", pair_id}], [:"$1"]}
      ])

    Enum.each(matches, &:ets.delete(@table, &1))
  end

  @doc """
  Checks if there are any registered routes for a pair_id.
  """
  @spec has_routes?(String.t()) :: boolean()
  def has_routes?(pair_id) when is_binary(pair_id) do
    init_table()

    case :ets.select(@table, [{{:"$1", :"$2"}, [{:==, :"$2", pair_id}], [true]}], 1) do
      {[true], _} -> true
      _ -> false
    end
  end

  @doc """
  Returns a list of all domain strings registered for a specific pair_id.
  """
  @spec routes_for_pair(String.t()) :: [String.t()]
  def routes_for_pair(pair_id) when is_binary(pair_id) do
    init_table()

    :ets.select(@table, [
      {{:"$1", :"$2"}, [{:==, :"$2", pair_id}], [:"$1"]}
    ])
  end

  @doc """
  Returns a summary of services and custom domains routed to a specific pair_id.
  """
  @spec routed_summary_for_pair(String.t()) :: %{services: [map()], custom_domains: [String.t()]}
  def routed_summary_for_pair(pair_id) when is_binary(pair_id) do
    all_domains = routes_for_pair(pair_id) |> MapSet.new()

    matched_services =
      Hermit.Services.Catalog.all()
      |> Enum.filter(fn svc ->
        Enum.any?(svc.domains, &MapSet.member?(all_domains, String.downcase(&1)))
      end)

    service_domain_set =
      matched_services
      |> Enum.flat_map(& &1.domains)
      |> Enum.flat_map(fn d ->
        norm = String.downcase(d)
        if String.starts_with?(norm, "*."), do: [norm, String.slice(norm, 2..-1//1)], else: [norm]
      end)
      |> MapSet.new()

    custom_domains =
      all_domains
      |> MapSet.difference(service_domain_set)
      |> MapSet.to_list()
      |> Enum.sort()

    %{
      services: matched_services,
      custom_domains: custom_domains
    }
  end

  @doc """
  Returns all domain patterns currently registered in the SNI Proxy ETS table.
  """
  @spec all_domains() :: [String.t()]
  def all_domains do
    init_table()

    :ets.tab2list(@table)
    |> Enum.flat_map(fn
      {domain, pair_id} when is_binary(domain) and is_binary(pair_id) -> [domain]
      _ -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Syncs all smart routes from database (Services + Custom Rules from all DNS profiles,
  plus legacy routing_targets from active tunnels) into the ETS table.
  """
  @spec sync_all_routes() :: :ok
  def sync_all_routes do
    init_table()

    # 1. Build a unified domain -> pair_id mapping with proper precedence:
    # Service Catalog -> Custom Rules overrides -> Legacy Routing Targets
    domain_mappings =
      try do
        Hermit.Repo.all(Hermit.Vpn.DnsConfig)
        |> Enum.reduce(%{}, fn profile, acc ->
          # A. Base: Service catalog rules
          acc =
            case profile.services do
              services when is_map(services) ->
                Enum.reduce(services, acc, fn {svc_id, cfg}, inner_acc ->
                  action = Map.get(cfg, "action") || Map.get(cfg, :action)
                  pair_id = Map.get(cfg, "pair_id") || Map.get(cfg, :pair_id)

                  if action == "route_tunnel" and is_binary(pair_id) and pair_id != "" do
                    domains = Hermit.Services.Catalog.domains_for_service(to_string(svc_id))

                    Enum.reduce(domains, inner_acc, fn d, d_acc ->
                      Map.put(d_acc, String.downcase(String.trim(d)), pair_id)
                    end)
                  else
                    inner_acc
                  end
                end)

              _ ->
                acc
            end

          # B. Override: Custom domain rules (always take precedence)
          case profile.custom_rules do
            rules when is_list(rules) ->
              Enum.reduce(rules, acc, fn rule, inner_acc ->
                action = Map.get(rule, "action") || Map.get(rule, :action)
                domain = Map.get(rule, "domain") || Map.get(rule, :domain)

                if Hermit.Vpn.DnsConfig.rule_enabled?(rule) and is_binary(domain) and
                     String.trim(domain) != "" do
                  domain_items =
                    domain
                    |> String.split([",", "\n", "\r", " "], trim: true)
                    |> Enum.map(&String.trim/1)
                    |> Enum.map(&String.downcase/1)
                    |> Enum.reject(&(&1 == ""))

                  case action do
                    act when act in ["route_tunnel", "smart_route"] ->
                      pair_id =
                        Map.get(rule, "value") || Map.get(rule, :value) ||
                          Map.get(rule, "proxy_pair_id") || Map.get(rule, :proxy_pair_id)

                      if is_binary(pair_id) and pair_id != "" do
                        Enum.reduce(domain_items, inner_acc, fn norm, m_acc ->
                          Map.put(m_acc, norm, pair_id)
                        end)
                      else
                        inner_acc
                      end

                    act when act in ["block", "bypass"] ->
                      Enum.reduce(domain_items, inner_acc, fn norm, m_acc ->
                        Map.delete(m_acc, norm)
                      end)

                    _ ->
                      inner_acc
                  end
                else
                  inner_acc
                end
              end)

            _ ->
              acc
          end
        end)
      rescue
        _ -> %{}
      end

    # 2. Incorporate legacy routing_targets from VpnPairs if any (without overwriting explicit rules)
    domain_mappings =
      try do
        Hermit.Repo.all(Hermit.Vpn.VpnPair)
        |> Enum.reduce(domain_mappings, fn pair, acc ->
          inbound_cfg = pair.inbound_config || %{}

          targets =
            Map.get(inbound_cfg, "routing_targets") || Map.get(inbound_cfg, :routing_targets) ||
              ""

          parsed = Hermit.Vpn.RoutingParser.parse(targets)

          Enum.reduce(parsed.domains, acc, fn d, inner_acc ->
            norm = String.downcase(String.trim(d))
            Map.put_new(inner_acc, norm, pair.pair_id)
          end)
        end)
      rescue
        _ -> domain_mappings
      end

    # 3. Group by pair_id
    pair_routes =
      Enum.reduce(domain_mappings, %{}, fn {domain, pair_id}, acc ->
        Map.update(acc, pair_id, [domain], &[domain | &1])
      end)

    # 4. Find existing pair_ids with routes currently in ETS
    existing_pairs =
      :ets.select(@table, [{{:"$1", :"$2"}, [], [:"$2"]}])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    all_pairs = Enum.uniq(existing_pairs ++ Map.keys(pair_routes))

    # 5. Update ETS for each pair
    Enum.each(all_pairs, fn pair_id ->
      domains = Map.get(pair_routes, pair_id, []) |> Enum.uniq()

      if domains != [] do
        register_routes(pair_id, domains)
      else
        unregister_pair(pair_id)
      end
    end)

    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.broadcast(Hermit.PubSub, "smart_routes", {:smart_routes_updated, all_pairs})
    end

    :ok
  end

  @doc """
  Matches a requested domain against the registered routes.
  Supports exact matching and wildcard matching.
  Returns `{:ok, pair_id}` or `:nomatch`.
  """
  @spec match(String.t()) :: {:ok, String.t()} | :nomatch
  def match(domain) when is_binary(domain) do
    init_table()
    norm = domain |> String.trim() |> String.downcase()
    do_match(norm)
  end

  def match(_), do: :nomatch

  defp do_match(domain) do
    # 1. Exact match
    case :ets.lookup(@table, domain) do
      [{^domain, pair_id}] ->
        {:ok, pair_id}

      [] ->
        # 2. Check wildcard match (e.g. "api.openai.com" -> "*.openai.com")
        case :binary.match(domain, ".") do
          {idx, _} ->
            parent = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
            wildcard = "*." <> parent

            case :ets.lookup(@table, wildcard) do
              [{^wildcard, pair_id}] ->
                {:ok, pair_id}

              [] ->
                do_match(parent)
            end

          :nomatch ->
            :nomatch
        end
    end
  end

  @doc """
  Retrieves all currently registered domain routes.
  """
  @spec all_routes() :: [{String.t(), String.t()}]
  def all_routes do
    init_table()

    :ets.tab2list(@table)
    |> Enum.filter(fn
      {domain, pair_id} when is_binary(domain) and is_binary(pair_id) -> true
      _ -> false
    end)
  end

  @doc """
  Gets the target host and port for SOCKS5 proxy for a given pair_id.
  Prefers direct connection to the namespace SOCKS daemon to eliminate loopback hop.
  """
  @spec get_socks5_target(String.t()) ::
          {:ok, tuple() | charlist(), pos_integer()} | {:error, term()}
  def get_socks5_target(pair_id) when is_binary(pair_id) do
    init_table()

    case :ets.lookup(@table, {:direct_target, pair_id}) do
      [{{:direct_target, ^pair_id}, {target_host, target_port}}] ->
        {:ok, target_host, target_port}

      _ ->
        case get_socks5_port(pair_id) do
          {:ok, port} -> {:ok, {127, 0, 0, 1}, port}
          error -> error
        end
    end
  end

  @doc """
  Gets the SOCKS5 proxy port for a given pair_id.
  """
  @spec get_socks5_port(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def get_socks5_port(pair_id) when is_binary(pair_id) do
    init_table()

    # 1. Check local @table cache first
    case :ets.lookup(@table, {:ports, pair_id}) do
      [{{:ports, ^pair_id}, socks5_port}] when is_integer(socks5_port) and socks5_port > 0 ->
        {:ok, socks5_port}

      _ ->
        # 2. Check :dns_proxy_cache ETS table
        case :ets.info(:dns_proxy_cache) do
          :undefined ->
            read_socks5_port_from_file(pair_id)

          _ ->
            case :ets.lookup(:dns_proxy_cache, {:ports, pair_id}) do
              [{_, {_http_port, socks5_port}}]
              when is_integer(socks5_port) and socks5_port > 0 ->
                :ets.insert(@table, {{:ports, pair_id}, socks5_port})
                {:ok, socks5_port}

              _ ->
                read_socks5_port_from_file(pair_id)
            end
        end
    end
  end

  defp read_socks5_port_from_file(pair_id) do
    storage_base =
      Application.get_env(:hermit, :storage, [])
      |> Keyword.get(:base_path, "/app/storage")

    info_path = Path.join([storage_base, pair_id, "proxy_info.json"])

    case File.read(info_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"socks5_port" => port} = data} when is_integer(port) and port > 0 ->
            http_port = Map.get(data, "http_port")

            # Cache in both tables for zero disk reads on future connections
            :ets.insert(@table, {{:ports, pair_id}, port})

            if :ets.info(:dns_proxy_cache) != :undefined do
              :ets.insert(:dns_proxy_cache, {{:ports, pair_id}, {http_port, port}})
            end

            {:ok, port}

          _ ->
            {:error, :invalid_proxy_info}
        end

      {:error, reason} ->
        {:error, {:no_proxy_info, reason}}
    end
  end
end
