defmodule Hermit.Dns.Filter do
  @moduledoc """
  Encapsulates logic for DNS blocklists and domain filtering.
  """

  @adult_domains MapSet.new([
                   "pornhub.com",
                   "xvideos.com",
                   "xnxx.com",
                   "redtube.com",
                   "youporn.com",
                   "chaturbate.com",
                   "stripchat.com",
                   "livejasmin.com",
                   "onlyfans.com"
                 ])

  @spec match_adult?(String.t()) :: boolean()
  def match_adult?(domain) do
    match_domain_set?(domain, @adult_domains)
  end

  @spec match_domain_set?(String.t(), MapSet.t()) :: boolean()
  def match_domain_set?(domain, set) do
    domain = String.downcase(domain)
    MapSet.member?(set, domain) or match_domain_set_recursive?(domain, set)
  end

  defp match_domain_set_recursive?(domain, set) do
    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        if MapSet.member?(set, suffix) do
          true
        else
          match_domain_set_recursive?(suffix, set)
        end
    end
  end

  @spec match_ets_blocklist?(String.t(), atom()) :: boolean()
  def match_ets_blocklist?(domain, table) do
    domain = String.downcase(domain)

    if :ets.member(table, domain) do
      true
    else
      match_suffix_recursive(domain, table)
    end
  end

  defp match_suffix_recursive(domain, table) do
    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        if :ets.member(table, suffix) do
          true
        else
          match_suffix_recursive(suffix, table)
        end
    end
  end
end
