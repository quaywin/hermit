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
  def precompile(rules) when is_list(rules) do
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

  def precompile(rules) when is_map(rules) do
    precompile(Map.get(rules, "custom_rules", []) || [])
  end

  def precompile(_), do: %{}
end
