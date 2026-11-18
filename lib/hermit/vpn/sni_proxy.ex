defmodule Hermit.Vpn.SniProxy do
  @moduledoc """
  Manages Smart DNS / SNI Proxy routing rules and provides
  route matching for incoming TLS (HTTPS) and HTTP connections.
  """

  @table :hermit_smart_routes

  @doc """
  Initializes the ETS table for smart domain routes.
  Called on application startup.
  """
  def init_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Registers a list of domains for a specific tunnel (pair_id).
  """
  @spec register_routes(String.t(), [String.t()]) :: :ok
  def register_routes(pair_id, domains) when is_binary(pair_id) and is_list(domains) do
    init_table()

    # First clean up old routes for this pair
    unregister_pair(pair_id)

    Enum.each(domains, fn domain ->
      norm = domain |> String.trim() |> String.downcase()

      if norm != "" do
        :ets.insert(@table, {norm, pair_id})

        # If it's a wildcard like *.domain.com, also match domain.com itself
        if String.starts_with?(norm, "*.") do
          base = String.slice(norm, 2..-1//1)
          :ets.insert(@table, {base, pair_id})
        end
      end
    end)

    :ok
  end

  @doc """
  Unregisters all routes belonging to a pair_id.
  """
  @spec unregister_pair(String.t()) :: :ok
  def unregister_pair(pair_id) when is_binary(pair_id) do
    init_table()

    matches =
      :ets.select(@table, [
        {{:"$1", :"$2"}, [{:==, :"$2", pair_id}], [:"$1"]}
      ])

    Enum.each(matches, &:ets.delete(@table, &1))
    :ok
  end

  @doc """
  Matches a requested domain against the registered routes.
  Supports exact matching and wildcard matching.
  Returns `{:ok, pair_id}` or `:nomatch`.
  """
  @spec match(String.t()) :: {:ok, String.t()} | :nomatch
  def match(domain) when is_binary(domain) do
    init_table()
    norm = domain |> String.trim() |> String.downcase()
    do_match(norm)
  end

  def match(_), do: :nomatch

  defp do_match(domain) do
    # 1. Exact match
    case :ets.lookup(@table, domain) do
      [{^domain, pair_id}] ->
        {:ok, pair_id}

      [] ->
        # 2. Check wildcard match (e.g. "api.openai.com" -> "*.openai.com")
        case :binary.match(domain, ".") do
          {idx, _} ->
            parent = binary_part(domain, idx + 1, byte_size(domain) - idx - 1)
            wildcard = "*." <> parent

            case :ets.lookup(@table, wildcard) do
              [{^wildcard, pair_id}] ->
                {:ok, pair_id}

              [] ->
                do_match(parent)
            end

          :nomatch ->
            :nomatch
        end
    end
  end

  @doc """
  Retrieves all currently registered domain routes.
  """
  @spec all_routes() :: [{String.t(), String.t()}]
  def all_routes do
    init_table()
    :ets.tab2list(@table)
  end

  @doc """
  Gets the SOCKS5 proxy port for a given pair_id.
  """
  @spec get_socks5_port(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def get_socks5_port(pair_id) when is_binary(pair_id) do
    # 1. Check :dns_proxy_cache ETS table first
    case :ets.info(:dns_proxy_cache) do
      :undefined ->
        read_socks5_port_from_file(pair_id)

      _ ->
        case :ets.lookup(:dns_proxy_cache, {:ports, pair_id}) do
          [{_, {_http_port, socks5_port}}] when is_integer(socks5_port) and socks5_port > 0 ->
            {:ok, socks5_port}

          _ ->
            read_socks5_port_from_file(pair_id)
        end
    end
  end

  defp read_socks5_port_from_file(pair_id) do
    storage_base =
      Application.get_env(:hermit, :storage, [])
      |> Keyword.get(:base_path, "/app/storage")

    info_path = Path.join([storage_base, pair_id, "proxy_info.json"])

    case File.read(info_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"socks5_port" => port}} when is_integer(port) and port > 0 ->
            {:ok, port}

          _ ->
            {:error, :invalid_proxy_info}
        end

      {:error, reason} ->
        {:error, {:no_proxy_info, reason}}
    end
  end
end
