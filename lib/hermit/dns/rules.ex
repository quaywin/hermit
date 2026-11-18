defmodule Hermit.Dns.Rules do
  @moduledoc """
  Handles matching and precompilation of custom DNS rules.
  """

  @spec match(String.t(), map()) ::
          {String.t(), String.t() | nil, String.t() | nil} | {nil, nil, nil}
  def match(_domain, rules_map) when map_size(rules_map) == 0, do: {nil, nil, nil}

  def match(domain, rules_map) do
    case Map.get(rules_map, domain) do
      {_action, _value, _proxy_pair_id} = result ->
        result

      nil ->
        case :binary.match(domain, ".") do
          {idx, _} ->
            parent = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
            match(parent, rules_map)

          :nomatch ->
            {nil, nil, nil}
        end
    end
  end

  @spec precompile(list() | map() | nil) :: map()
  def precompile(%Hermit.Vpn.DnsConfig{} = config) do
    precompile_config(config.custom_rules, config.services)
  end

  def precompile(config)
      when is_map(config) and
             (is_map_key(config, :services) or is_map_key(config, "services")) do
    custom_rules = Map.get(config, :custom_rules) || Map.get(config, "custom_rules", []) || []
    services = Map.get(config, :services) || Map.get(config, "services", %{}) || %{}
    precompile_config(custom_rules, services)
  end

  def precompile(rules) when is_list(rules) do
    precompile_rules_list(rules)
  end

  def precompile(rules) when is_map(rules) do
    precompile_rules_list(Map.get(rules, "custom_rules", []) || [])
  end

  def precompile(_), do: %{}

  defp precompile_config(custom_rules, services) do
    service_rules =
      if is_map(services) do
        Enum.flat_map(services, fn {svc_id, cfg} ->
          action = Map.get(cfg, "action") || Map.get(cfg, :action)
          pair_id = Map.get(cfg, "pair_id") || Map.get(cfg, :pair_id)
          domains = Hermit.Services.Catalog.domains_for_service(to_string(svc_id))

          case action do
            "block" ->
              Enum.map(domains, fn d -> %{"domain" => d, "action" => "block", "value" => nil} end)

            "bypass" ->
              Enum.map(domains, fn d -> %{"domain" => d, "action" => "bypass", "value" => nil} end)

            "route_tunnel" when is_binary(pair_id) and pair_id != "" ->
              Enum.map(domains, fn d ->
                %{"domain" => d, "action" => "route_tunnel", "value" => pair_id}
              end)

            _ ->
              []
          end
        end)
      else
        []
      end

    # Put service_rules first and custom_rules second so that custom_rules take precedence
    all_rules = service_rules ++ (custom_rules || [])
    precompile_rules_list(all_rules)
  end

  defp precompile_rules_list(rules) when is_list(rules) do
    rules
    |> Enum.flat_map(fn rule ->
      domain = Map.get(rule, "domain") || Map.get(rule, :domain)
      action = Map.get(rule, "action") || Map.get(rule, :action)
      value = Map.get(rule, "value") || Map.get(rule, :value)
      proxy_pair_id = Map.get(rule, "proxy_pair_id") || Map.get(rule, :proxy_pair_id)

      if is_binary(domain) and String.trim(domain) != "" do
        norm_domain = domain |> String.trim() |> String.downcase()

        clean_domain =
          if String.starts_with?(norm_domain, "*."),
            do: String.slice(norm_domain, 2..-1//1),
            else: norm_domain

        entry = {action, value, proxy_pair_id}

        if clean_domain != norm_domain do
          [{norm_domain, entry}, {clean_domain, entry}]
        else
          [{norm_domain, entry}]
        end
      else
        []
      end
    end)
    |> Map.new()
  end

  defp precompile_rules_list(_), do: %{}
end
