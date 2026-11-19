defmodule Hermit.Dns.Filter do
  @moduledoc """
  Encapsulates logic for DNS blocklists and domain filtering.
  """
  import Bitwise

  @filter_cache_table :dns_filter_cache
  @max_filter_cache_entries 50_000
  @eviction_batch_size 5_000

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
    if Hermit.Dns.BloomFilter.member_downcased?(domain, bloom_binary) do
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
    bit = 1 <<< (blocklist_id - 1)

    case :ets.lookup(:dns_blocklist_entries, domain) do
      [{^domain, mask}] when is_integer(mask) ->
        (mask &&& bit) != 0 or match_suffix_recursive_dynamic(domain, blocklist_id)

      _ ->
        match_suffix_recursive_dynamic(domain, blocklist_id)
    end
  end

  @spec match_any_ets_blocklist_cached?(String.t(), [integer()]) :: integer() | nil
  def match_any_ets_blocklist_cached?(domain, blocklist_ids) do
    norm_domain = String.downcase(domain)
    cache_key = {norm_domain, blocklist_ids}

    try do
      case :ets.lookup(@filter_cache_table, cache_key) do
        [{_, matched_id, _}] ->
          matched_id

        [{_, matched_id}] ->
          matched_id

        [] ->
          matched_id = match_any_ets_blocklist_downcased?(norm_domain, blocklist_ids)
          now = System.monotonic_time(:second)
          maybe_prune_filter_cache(now)
          :ets.insert(@filter_cache_table, {cache_key, matched_id, now})
          matched_id
      end
    rescue
      ArgumentError ->
        ensure_filter_cache_table_exists()
        match_any_ets_blocklist_downcased?(norm_domain, blocklist_ids)
    end
  end

  defp maybe_prune_filter_cache(now) do
    case :ets.info(@filter_cache_table, :size) do
      size when is_integer(size) and size >= @max_filter_cache_entries ->
        case :ets.lookup(@filter_cache_table, :_last_eviction) do
          [{_, last_eviction}] when now - last_eviction < 10 ->
            :ok

          _ ->
            :ets.insert(@filter_cache_table, {:_last_eviction, now})
            evict_filter_cache_batch(@eviction_batch_size)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp evict_filter_cache_batch(count) do
    case :ets.select(
           @filter_cache_table,
           [{{{:"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}],
           count
         ) do
      {keys, _cont} when is_list(keys) ->
        Enum.each(keys, &:ets.delete(@filter_cache_table, &1))

      _ ->
        :ok
    end
  end

  defp ensure_filter_cache_table_exists do
    if :ets.info(@filter_cache_table) == :undefined do
      try do
        :ets.new(@filter_cache_table, [
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
    match_any_ets_blocklist_downcased?(String.downcase(domain), blocklist_ids)
  end

  defp match_any_ets_blocklist_downcased?(domain, blocklist_ids) do
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
    target_mask =
      Enum.reduce(blocklist_ids, 0, fn id, acc ->
        acc ||| (1 <<< (id - 1))
      end)

    case :ets.lookup(:dns_blocklist_entries, domain) do
      [{^domain, mask}] when is_integer(mask) ->
        if (mask &&& target_mask) != 0 do
          find_matched_id(mask, blocklist_ids)
        else
          match_any_suffix_recursive(domain, blocklist_ids, target_mask)
        end

      _ ->
        match_any_suffix_recursive(domain, blocklist_ids, target_mask)
    end
  end

  defp match_any_suffix_recursive(domain, blocklist_ids, target_mask) do
    case :binary.match(domain, ".") do
      :nomatch ->
        nil

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        case :ets.lookup(:dns_blocklist_entries, suffix) do
          [{^suffix, mask}] when is_integer(mask) ->
            if (mask &&& target_mask) != 0 do
              find_matched_id(mask, blocklist_ids)
            else
              match_any_suffix_recursive(suffix, blocklist_ids, target_mask)
            end

          _ ->
            match_any_suffix_recursive(suffix, blocklist_ids, target_mask)
        end
    end
  end

  defp match_suffix_recursive_dynamic(domain, blocklist_id) do
    bit = 1 <<< (blocklist_id - 1)

    case :binary.match(domain, ".") do
      :nomatch ->
        false

      {idx, _len} ->
        suffix = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)

        case :ets.lookup(:dns_blocklist_entries, suffix) do
          [{^suffix, mask}] when is_integer(mask) ->
            if (mask &&& bit) != 0 do
              true
            else
              match_suffix_recursive_dynamic(suffix, blocklist_id)
            end

          _ ->
            match_suffix_recursive_dynamic(suffix, blocklist_id)
        end
    end
  end

  defp find_matched_id(mask, blocklist_ids) do
    Enum.find(blocklist_ids, fn id ->
      (mask &&& (1 <<< (id - 1))) != 0
    end)
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
