defmodule Hermit.Dns.Filter do
  @moduledoc """
  Encapsulates logic for DNS blocklists and domain filtering.
  """

  @spec match_global_ets_blocklist?(String.t()) :: integer() | nil
  def match_global_ets_blocklist?(domain) do
    domain = String.downcase(domain)

    # Fast path: Check Bloom Filter first. If clean, skip ETS lookup entirely.
    if any_bloom_member?(domain) do
      case :ets.lookup(:dns_blocklist_entries, domain) do
        [] ->
          match_global_suffix_recursive(domain)

        [{_, id} | _] ->
          id
      end
    else
      nil
    end
  end

  defp any_bloom_member?(domain) do
    if :ets.info(:dns_bloom_filter) == :undefined do
      true
    else
      case :ets.tab2list(:dns_bloom_filter) do
        [] -> true
        filters -> any_bloom_member_recursive?(domain, filters)
      end
    end
  end

  defp any_bloom_member_recursive?(domain, filters) do
    matched =
      Enum.any?(filters, fn {_, bloom_binary} ->
        Hermit.Dns.BloomFilter.member?(domain, bloom_binary)
      end)

    if matched do
      true
    else
      case :binary.match(domain, ".") do
        :nomatch ->
          false

        {idx, _len} ->
          suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
          any_bloom_member_recursive?(suffix, filters)
      end
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

    # Check Bloom Filter for the specific blocklist
    bloom_match =
      if :ets.info(:dns_bloom_filter) != :undefined do
        case :ets.lookup(:dns_bloom_filter, blocklist_id) do
          [{_, bloom_binary}] ->
            bloom_member_recursive?(domain, bloom_binary)

          _ ->
            true
        end
      else
        true
      end

    if bloom_match do
      do_match_ets_blocklist?(domain, blocklist_id)
    else
      false
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

  defp bloom_member_recursive?(domain, bloom_binary) do
    if Hermit.Dns.BloomFilter.member?(domain, bloom_binary) do
      true
    else
      case :binary.match(domain, ".") do
        :nomatch ->
          false

        {idx, _len} ->
          suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
          bloom_member_recursive?(suffix, bloom_binary)
      end
    end
  end

  defp do_match_ets_blocklist?(domain, blocklist_id) do
    case :ets.lookup(:dns_blocklist_entries, domain) do
      [] ->
        match_suffix_recursive_dynamic(domain, blocklist_id)

      tuples ->
        Enum.any?(tuples, fn {_, id} -> id == blocklist_id end) or
          match_suffix_recursive_dynamic(domain, blocklist_id)
    end
  end

  @spec match_any_ets_blocklist_cached?(String.t(), [integer()]) :: integer() | nil
  def match_any_ets_blocklist_cached?(domain, blocklist_ids) do
    ensure_filter_cache_table_exists()
    cache_key = {domain, blocklist_ids}

    case :ets.lookup(:dns_filter_cache, cache_key) do
      [{_, matched_id}] ->
        matched_id

      [] ->
        matched_id = match_any_ets_blocklist?(domain, blocklist_ids)
        :ets.insert(:dns_filter_cache, {cache_key, matched_id})
        matched_id
    end
  end

  defp ensure_filter_cache_table_exists do
    if :ets.info(:dns_filter_cache) == :undefined do
      try do
        :ets.new(:dns_filter_cache, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: :auto
        ])
      rescue
        _ -> :ok
      end
    end
  end

  @spec match_any_ets_blocklist?(String.t(), [integer()]) :: integer() | nil
  def match_any_ets_blocklist?(domain, blocklist_ids) do
    domain = String.downcase(domain)

    # Filter blocklist_ids using Bloom Filter
    active_ids =
      if :ets.info(:dns_bloom_filter) != :undefined do
        Enum.filter(blocklist_ids, fn id ->
          case :ets.lookup(:dns_bloom_filter, id) do
            [{_, bloom_binary}] ->
              bloom_member_recursive?(domain, bloom_binary)

            _ ->
              true
          end
        end)
      else
        blocklist_ids
      end

    if active_ids == [] do
      nil
    else
      do_match_any_ets_blocklist?(domain, active_ids)
    end
  end

  defp do_match_any_ets_blocklist?(domain, blocklist_ids) do
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
