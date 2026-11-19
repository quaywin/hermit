defmodule Hermit.Dns.Cache do
  @moduledoc """
  Encapsulates DNS caching logic using the global `:dns_cache` ETS table.
  """

  @dns_cache_table :dns_cache
  @max_entries 25_000
  @eviction_batch_size 2_500
  @delete_chunk_size 1_000

  @spec lookup(integer(), String.t(), atom(), boolean()) ::
          {:ok, binary(), String.t(), String.t()}
          | {:stale, binary(), String.t(), String.t()}
          | :error
  def lookup(profile_id, domain, qtype, allow_stale? \\ false) do
    domain = String.downcase(domain)
    now = System.monotonic_time(:second)

    case :ets.lookup(@dns_cache_table, {profile_id, domain, qtype}) do
      [{{^profile_id, ^domain, ^qtype}, resp_packet, status, answer_log_info, expires_at}] ->
        if now < expires_at do
          {:ok, resp_packet, status, answer_log_info}
        else
          if allow_stale? do
            {:stale, resp_packet, status, answer_log_info}
          else
            :error
          end
        end

      _ ->
        :error
    end
  end

  @spec store(integer(), String.t(), atom(), binary(), String.t(), String.t(), integer()) :: :ok
  def store(profile_id, domain, qtype, resp_packet, status, answer_log_info, ttl) do
    domain = String.downcase(domain)
    expires_at = System.monotonic_time(:second) + ttl

    maybe_prune_overflow()

    :ets.insert(
      @dns_cache_table,
      {{profile_id, domain, qtype}, resp_packet, status, answer_log_info, expires_at}
    )

    :ok
  end

  @doc """
  Deletes expired entries from the cache.
  """
  @spec prune_expired() :: :ok
  def prune_expired do
    now = System.monotonic_time(:second)

    :ets.select_delete(@dns_cache_table, [
      {{{:_, :_, :_}, :_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_prune_overflow do
    now = System.monotonic_time(:second)

    case :ets.info(@dns_cache_table, :size) do
      size when is_integer(size) and size >= @max_entries ->
        case :ets.lookup(@dns_cache_table, :_last_overflow_prune) do
          [{_, last_prune}] when now - last_prune < 10 ->
            :ok

          _ ->
            :ets.insert(@dns_cache_table, {:_last_overflow_prune, now})
            prune_expired()

            # Enforce a hard memory ceiling even if all cached entries are still unexpired
            case :ets.info(@dns_cache_table, :size) do
              remaining when is_integer(remaining) and remaining >= @max_entries ->
                evict_batch(@eviction_batch_size)

              _ ->
                :ok
            end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp evict_batch(count) do
    case :ets.select(
           @dns_cache_table,
           [{{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [], [{{:"$1", :"$2", :"$3"}}]}],
           count
         ) do
      {keys, _cont} when is_list(keys) ->
        Enum.each(keys, &:ets.delete(@dns_cache_table, &1))

      _ ->
        :ok
    end
  end

  @spec clear(integer()) :: :ok
  def clear(profile_id) do
    :ets.select_delete(@dns_cache_table, [
      {{{profile_id, :_, :_}, :_, :_, :_, :_}, [], [true]}
    ])

    :ok
  end

  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@dns_cache_table)
    :ok
  end

  @doc """
  Deletes cache entries matching a domain or wildcard domain across all profiles.
  Used when Smart Routes are updated to immediately invalidate stale upstream DNS responses.
  """
  @spec delete_domain(String.t()) :: :ok
  def delete_domain(domain) when is_binary(domain) do
    norm = domain |> String.trim() |> String.downcase()

    if String.starts_with?(norm, "*.") do
      suffix = String.slice(norm, 1..-1//1)
      base = String.slice(norm, 2..-1//1)

      :ets.select_delete(@dns_cache_table, [
        {{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [{:==, :"$2", base}], [true]}
      ])

      delete_matching_suffix_chunked(suffix)
    else
      :ets.select_delete(@dns_cache_table, [
        {{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [{:==, :"$2", norm}], [true]}
      ])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp delete_matching_suffix_chunked(suffix) do
    :ets.safe_fixtable(@dns_cache_table, true)

    try do
      match_spec = [{{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [], [{{:"$1", :"$2", :"$3"}}]}]

      do_delete_suffix_chunk(
        :ets.select(@dns_cache_table, match_spec, @delete_chunk_size),
        suffix
      )
    after
      :ets.safe_fixtable(@dns_cache_table, false)
    end
  end

  defp do_delete_suffix_chunk(:"$end_of_table", _suffix), do: :ok

  defp do_delete_suffix_chunk({keys, cont}, suffix) do
    Enum.each(keys, fn {p_id, d, qtype} ->
      if String.ends_with?(d, suffix) do
        :ets.delete(@dns_cache_table, {p_id, d, qtype})
      end
    end)

    do_delete_suffix_chunk(:ets.select(cont), suffix)
  end
end
