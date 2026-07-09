defmodule Hermit.Dns.Filter do
  @moduledoc """
  Encapsulates logic for DNS blocklists and domain filtering.
  """

  @spec match_global_ets_blocklist?(String.t()) :: integer() | nil
  def match_global_ets_blocklist?(domain) do
    domain = String.downcase(domain)

    case :ets.lookup(:dns_blocklist_entries, domain) do
      [] ->
        match_global_suffix_recursive(domain)

      [{_, id} | _] ->
        id
    end
  end

  defp match_global_suffix_recursive(domain) do
    case :binary.match(domain, ".") do
      :nomatch ->
        nil

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        case :ets.lookup(:dns_blocklist_entries, suffix) do
          [] ->
            match_global_suffix_recursive(suffix)

          [{_, id} | _] ->
            id
        end
    end
  end

  @spec match_adult?(String.t()) :: boolean()
  def match_adult?(domain) do
    match_ets_blocklist?(domain, 3)
  end

  @spec match_ets_blocklist?(String.t(), atom() | integer()) :: boolean()
  def match_ets_blocklist?(domain, :adguard_blocklist), do: match_ets_blocklist?(domain, 1)
  def match_ets_blocklist?(domain, :goodbyeads_blocklist), do: match_ets_blocklist?(domain, 2)
  def match_ets_blocklist?(domain, :adult_blocklist), do: match_ets_blocklist?(domain, 3)

  def match_ets_blocklist?(domain, blocklist_id) when is_integer(blocklist_id) do
    domain = String.downcase(domain)

    case :ets.lookup(:dns_blocklist_entries, domain) do
      [] ->
        match_suffix_recursive_dynamic(domain, blocklist_id)

      tuples ->
        Enum.any?(tuples, fn {_, id} -> id == blocklist_id end) or
          match_suffix_recursive_dynamic(domain, blocklist_id)
    end
  end

  def match_ets_blocklist?(domain, table) when is_atom(table) do
    domain = String.downcase(domain)

    if :ets.member(table, domain) do
      true
    else
      match_suffix_recursive(domain, table)
    end
  end

  @spec match_any_ets_blocklist?(String.t(), [integer()]) :: integer() | nil
  def match_any_ets_blocklist?(domain, blocklist_ids) do
    domain = String.downcase(domain)

    case :ets.lookup(:dns_blocklist_entries, domain) do
      [] ->
        match_any_suffix_recursive(domain, blocklist_ids)

      tuples ->
        Enum.find_value(tuples, fn {_, id} ->
          if id in blocklist_ids, do: id
        end) || match_any_suffix_recursive(domain, blocklist_ids)
    end
  end

  defp match_any_suffix_recursive(domain, blocklist_ids) do
    case :binary.match(domain, ".") do
      :nomatch ->
        nil

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        case :ets.lookup(:dns_blocklist_entries, suffix) do
          [] ->
            match_any_suffix_recursive(suffix, blocklist_ids)

          tuples ->
            matched_id =
              Enum.find_value(tuples, fn {_, id} ->
                if id in blocklist_ids, do: id
              end)

            if matched_id do
              matched_id
            else
              match_any_suffix_recursive(suffix, blocklist_ids)
            end
        end
    end
  end

  defp match_suffix_recursive_dynamic(domain, blocklist_id) do
    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        case :ets.lookup(:dns_blocklist_entries, suffix) do
          [] ->
            match_suffix_recursive_dynamic(suffix, blocklist_id)

          tuples ->
            if Enum.any?(tuples, fn {_, id} -> id == blocklist_id end) do
              true
            else
              match_suffix_recursive_dynamic(suffix, blocklist_id)
            end
        end
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
