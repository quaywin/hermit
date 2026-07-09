defmodule Hermit.Dns.Cache do
  @moduledoc """
  Encapsulates DNS caching logic using the global `:dns_cache` ETS table.
  """

  @dns_cache_table :dns_cache

  @spec lookup(integer(), String.t(), atom(), boolean()) :: {:ok, binary(), String.t(), String.t()} | {:stale, binary(), String.t(), String.t()} | :error
  def lookup(profile_id, domain, qtype, allow_stale? \\ false) do
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
    expires_at = System.monotonic_time(:second) + ttl

    :ets.insert(
      @dns_cache_table,
      {{profile_id, domain, qtype}, resp_packet, status, answer_log_info, expires_at}
    )

    :ok
  end
end
