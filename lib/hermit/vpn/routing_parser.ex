defmodule Hermit.Vpn.RoutingParser do
  @moduledoc """
  Parses a unified routing string (containing domains and IP subnets)
  and classifies entries into:
    - `subnets`: IP addresses / CIDRs for Tailscale Subnet Routing
    - `domains`: Hostnames / wildcard domains for Smart DNS & SNI Proxy
  """

  @type parsed_routing :: %{
          subnets: [String.t()],
          domains: [String.t()],
          raw: String.t()
        }

  @spec parse(String.t() | nil) :: parsed_routing()
  def parse(nil), do: %{subnets: [], domains: [], raw: ""}
  def parse(""), do: %{subnets: [], domains: [], raw: ""}

  def parse(raw_input) when is_binary(raw_input) do
    entries =
      raw_input
      |> String.split([",", "\n", "\r", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {subnets, domains} =
      Enum.reduce(entries, {[], []}, fn item, {acc_subnets, acc_domains} ->
        item_lower = String.downcase(item)

        case classify(item_lower) do
          {:subnet, subnet} ->
            {[subnet | acc_subnets], acc_domains}

          {:domain, domain} ->
            {acc_subnets, [domain | acc_domains]}

          :ignore ->
            {acc_subnets, acc_domains}
        end
      end)

    %{
      subnets: Enum.reverse(subnets) |> Enum.uniq(),
      domains: Enum.reverse(domains) |> Enum.uniq(),
      raw: raw_input
    }
  end

  @doc """
  Formats parsed routing back to comma-separated subnets string for Tailscale.
  """
  @spec format_subnets([String.t()]) :: String.t()
  def format_subnets(subnets) when is_list(subnets) do
    Enum.join(subnets, ",")
  end

  # ============================================================================
  # Internal Classifiers
  # ============================================================================

  defp classify(item) do
    cond do
      subnet = parse_ip_or_cidr(item) ->
        {:subnet, subnet}

      domain = parse_domain(item) ->
        {:domain, domain}

      true ->
        :ignore
    end
  end

  defp parse_ip_or_cidr(item) do
    case String.split(item, "/", parts: 2) do
      [ip_str, prefix_str] ->
        with {:ok, _tuple} <- :inet.parse_address(String.to_charlist(ip_str)),
             {prefix, ""} <- Integer.parse(prefix_str),
             true <- valid_prefix?(ip_str, prefix) do
          "#{ip_str}/#{prefix}"
        else
          _ -> nil
        end

      [ip_str] ->
        case :inet.parse_address(String.to_charlist(ip_str)) do
          {:ok, {_, _, _, _}} ->
            "#{ip_str}/32"

          {:ok, {_, _, _, _, _, _, _, _}} ->
            "#{ip_str}/128"

          _ ->
            nil
        end
    end
  end

  defp valid_prefix?(ip_str, prefix) when prefix >= 0 do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, {_, _, _, _}} -> prefix <= 32
      {:ok, {_, _, _, _, _, _, _, _}} -> prefix <= 128
      _ -> false
    end
  end

  defp valid_prefix?(_ip_str, _prefix), do: false

  defp parse_domain(item) do
    # Handle wildcard domains: *.domain.com
    {has_wildcard?, clean_item} =
      if String.starts_with?(item, "*.") do
        {true, String.slice(item, 2..-1//1)}
      else
        {false, item}
      end

    if valid_domain_syntax?(clean_item) do
      if has_wildcard?, do: "*.#{clean_item}", else: clean_item
    else
      nil
    end
  end

  defp valid_domain_syntax?(domain) do
    # Must have at least one dot, no spaces or slashes.
    # The TLD (last label) must not be purely numeric (e.g. 999.999.999.999 is not a domain).
    if String.contains?(domain, ".") and not String.contains?(domain, "/") and
         not String.contains?(domain, " ") and not String.starts_with?(domain, ".") and
         not String.ends_with?(domain, ".") do
      labels = String.split(domain, ".")
      tld = List.last(labels)

      valid_labels? =
        Enum.all?(labels, fn label ->
          byte_size(label) >= 1 and byte_size(label) <= 63 and
            Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, label)
        end)

      # TLD must contain at least one letter
      tld_has_letter? = Regex.match?(~r/[a-z]/, tld)

      valid_labels? and tld_has_letter?
    else
      false
    end
  end
end
