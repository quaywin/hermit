defmodule Hermit.Dns.Cache do
  @moduledoc """
  Owns shared DNS ETS tables and encapsulates DNS caching logic using `:dns_cache`.
  """

  use GenServer

  @dns_cache_table :dns_cache
  @max_entries 25_000
  @eviction_batch_size 2_500
  @delete_chunk_size 1_000
  @prune_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_tables()
    :erlang.send_after(@prune_interval_ms, self(), :prune_cache)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune_cache, state) do
    prune_expired()
    :erlang.send_after(@prune_interval_ms, self(), :prune_cache)
    {:noreply, state}
  end

  defp ensure_tables do
    ensure_table(@dns_cache_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    ensure_table(:inbound_profiles_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])

    ensure_table(:dns_proxy_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: :auto
    ])
  end

  defp ensure_table(name, opts) do
    if :ets.info(name) == :undefined do
      :ets.new(name, opts)
    end
  end

  @spec lookup(integer(), boolean(), String.t(), atom(), boolean()) ::
          {:ok, binary(), String.t(), String.t()}
          | {:stale, binary(), String.t(), String.t()}
          | :error
  def lookup(profile_id, is_internal, domain, qtype, allow_stale?) when is_boolean(is_internal) do
    domain = String.downcase(domain)
    now = System.monotonic_time(:second)
    key = {profile_id, is_internal, domain, qtype}

    case :ets.lookup(@dns_cache_table, key) do
      [{^key, resp_packet, status, answer_log_info, expires_at}] ->
        check_expiration(resp_packet, status, answer_log_info, expires_at, now, allow_stale?)

      _ ->
        legacy_key = {profile_id, domain, qtype}

        case :ets.lookup(@dns_cache_table, legacy_key) do
          [{^legacy_key, resp_packet, status, answer_log_info, expires_at}] ->
            check_expiration(resp_packet, status, answer_log_info, expires_at, now, allow_stale?)

          _ ->
            :error
        end
    end
  end

  def lookup(profile_id, domain, qtype) do
    lookup(profile_id, true, domain, qtype, false)
  end

  def lookup(profile_id, is_internal, domain, qtype) when is_boolean(is_internal) do
    lookup(profile_id, is_internal, domain, qtype, false)
  end

  @spec lookup(integer(), String.t(), atom(), boolean()) ::
          {:ok, binary(), String.t(), String.t()}
          | {:stale, binary(), String.t(), String.t()}
          | :error
  def lookup(profile_id, domain, qtype, allow_stale?) when is_boolean(allow_stale?) do
    lookup(profile_id, true, domain, qtype, allow_stale?)
  end

  defp check_expiration(resp_packet, status, answer_log_info, expires_at, now, allow_stale?) do
    if now < expires_at do
      {:ok, resp_packet, status, answer_log_info}
    else
      if allow_stale? do
        {:stale, resp_packet, status, answer_log_info}
      else
        :error
      end
    end
  end

  @spec store(
          integer(),
          boolean(),
          String.t(),
          atom(),
          binary(),
          String.t(),
          String.t(),
          integer()
        ) :: :ok
  def store(profile_id, is_internal, domain, qtype, resp_packet, status, answer_log_info, ttl)
      when is_boolean(is_internal) do
    domain = String.downcase(domain)
    expires_at = System.monotonic_time(:second) + ttl

    maybe_prune_overflow()

    :ets.insert(
      @dns_cache_table,
      {{profile_id, is_internal, domain, qtype}, resp_packet, status, answer_log_info, expires_at}
    )

    :ok
  end

  @spec store(integer(), String.t(), atom(), binary(), String.t(), String.t(), integer()) :: :ok
  def store(profile_id, domain, qtype, resp_packet, status, answer_log_info, ttl) do
    store(profile_id, true, domain, qtype, resp_packet, status, answer_log_info, ttl)
  end

  @doc """
  Deletes expired entries from the cache.
  """
  @spec prune_expired() :: :ok
  def prune_expired do
    now = System.monotonic_time(:second)

    :ets.select_delete(@dns_cache_table, [
      {{{:_, :_, :_, :_}, :_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]},
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
           [
             {{{:"$1", :"$2", :"$3", :"$4"}, :_, :_, :_, :_}, [],
              [{{:"$1", :"$2", :"$3", :"$4"}}]},
             {{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [], [{{:"$1", :"$2", :"$3"}}]}
           ],
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
      {{{profile_id, :_, :_, :_}, :_, :_, :_, :_}, [], [true]},
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
        {{{:"$1", :"$2", :"$3", :"$4"}, :_, :_, :_, :_}, [{:==, :"$3", base}], [true]},
        {{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [{:==, :"$2", base}], [true]}
      ])

      delete_matching_suffix_chunked(suffix)
    else
      :ets.select_delete(@dns_cache_table, [
        {{{:"$1", :"$2", :"$3", :"$4"}, :_, :_, :_, :_}, [{:==, :"$3", norm}], [true]},
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
      match_spec = [
        {{{:"$1", :"$2", :"$3", :"$4"}, :_, :_, :_, :_}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]},
        {{{:"$1", :"$2", :"$3"}, :_, :_, :_, :_}, [], [{{:"$1", :"$2", :"$3"}}]}
      ]

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
    Enum.each(keys, fn
      {p_id, is_int, d, qtype} ->
        if String.ends_with?(d, suffix) do
          :ets.delete(@dns_cache_table, {p_id, is_int, d, qtype})
        end

      {p_id, d, qtype} ->
        if String.ends_with?(d, suffix) do
          :ets.delete(@dns_cache_table, {p_id, d, qtype})
        end
    end)

    do_delete_suffix_chunk(:ets.select(cont), suffix)
  end
end
