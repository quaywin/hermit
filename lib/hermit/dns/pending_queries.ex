defmodule Hermit.Dns.PendingQueries do
  @moduledoc """
  Manages per-endpoint ETS tables of in-flight upstream DNS queries,
  providing atomic 16-bit Transaction ID allocation and timeout candidate selection.
  """

  @spec ensure_table(term()) :: atom()
  def ensure_table(endpoint_id) do
    pending_table = :"dns_pending_queries_#{endpoint_id}"

    if :ets.info(pending_table) == :undefined do
      :ets.new(pending_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: :auto
      ])
    end

    pending_table
  end

  @spec register(atom(), tuple()) :: pos_integer()
  def register(pending_table, query_info) do
    base_id = rem(System.unique_integer([:positive, :monotonic]), 65535) + 1
    do_register(pending_table, query_info, base_id, 0)
  end

  defp do_register(pending_table, query_info, candidate_id, retries) when retries < 100 do
    if :ets.insert_new(pending_table, {candidate_id, query_info}) do
      candidate_id
    else
      next_candidate = if candidate_id >= 65535, do: 1, else: candidate_id + 1
      do_register(pending_table, query_info, next_candidate, retries + 1)
    end
  end

  defp do_register(pending_table, query_info, candidate_id, _retries) do
    :ets.insert(pending_table, {candidate_id, query_info})
    candidate_id
  end

  @spec expired_candidates(atom(), integer()) :: [tuple()]
  def expired_candidates(pending_table, cutoff_ms) do
    head = {:"$1", {:_, :_, :_, :"$2", :"$3", :"$4", :_}}
    guard = [{:"=<", :"$2", cutoff_ms}]
    result = [{{:"$1", :"$2", :"$3", :"$4"}}]
    :ets.select(pending_table, [{head, guard, result}])
  end
end
