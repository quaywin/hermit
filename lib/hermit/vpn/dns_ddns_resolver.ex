defmodule Hermit.Vpn.DnsDdnsResolver do
  use GenServer
  require Logger
  import Ecto.Query

  @table :dns_ddns_cache
  # Update frequency: 60 seconds
  @update_interval 60_000

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up the endpoint_id associated with a client IP address string.
  Returns {:ok, endpoint_id} or :not_found.
  """
  def lookup_endpoint_id(client_ip) when is_binary(client_ip) do
    try do
      case :ets.lookup(@table, {:ip, client_ip}) do
        [{_, endpoint_id}] -> {:ok, endpoint_id}
        [] -> :not_found
      end
    rescue
      _ -> :not_found
    end
  end

  def lookup_endpoint_id(_), do: :not_found

  @doc """
  Returns a map of %{endpoint_id => %{hostname: hostname, ip: ip, updated_at: status}} for UI.
  """
  def get_resolved_ddns_map do
    try do
      :ets.match_object(@table, {{:endpoint, :_}, :_})
      |> Enum.map(fn {{:endpoint, endpoint_id}, info} -> {endpoint_id, info} end)
      |> Enum.into(%{})
    rescue
      _ -> %{}
    end
  end

  @doc """
  Triggers an immediate resolution sync of all DDNS hostnames.
  """
  def trigger_sync do
    GenServer.cast(__MODULE__, :sync_now)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Perform initial sync shortly after boot
    Process.send_after(self(), :periodic_sync, 1000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:periodic_sync, state) do
    do_sync()
    Process.send_after(self(), :periodic_sync, @update_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    do_sync()
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp do_sync do
    endpoints =
      try do
        Hermit.Repo.all(
          from(e in Hermit.Vpn.DnsEndpoint,
            where: e.enabled == true and not is_nil(e.ddns_hostname) and e.ddns_hostname != ""
          )
        )
      rescue
        _ -> []
      end

    Task.async_stream(
      endpoints,
      fn endpoint ->
        hostname = String.trim(endpoint.ddns_hostname)

        case resolve_hostname(hostname) do
          {:ok, ip_str} ->
            existing_ip =
              case :ets.lookup(@table, {:endpoint, endpoint.id}) do
                [{_, %{ip: current_ip}}] -> current_ip
                _ -> nil
              end

            if existing_ip != ip_str do
              Logger.info(
                "DnsDdnsResolver: Resolved DDNS for Endpoint '#{endpoint.name}' (#{hostname}) -> #{ip_str}"
              )

              # Remove previous IP mapping if it changed
              if existing_ip do
                :ets.delete(@table, {:ip, existing_ip})
              end

              # Store new IP mapping and endpoint info
              :ets.insert(@table, {{:ip, ip_str}, endpoint.id})
              :ets.insert(@table, {{:endpoint, endpoint.id}, %{
                hostname: hostname,
                ip: ip_str,
                updated_at: DateTime.utc_now()
              }})
            end

          {:error, reason} ->
            Logger.warning(
              "DnsDdnsResolver: Failed to resolve DDNS hostname '#{hostname}' for Endpoint '#{endpoint.name}': #{inspect(reason)}"
            )
        end
      end,
      max_concurrency: 8,
      timeout: 3000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp resolve_hostname(hostname) when is_binary(hostname) do
    charlist_host = String.to_charlist(hostname)

    # First try fast asynchronous Erlang DNS resolver with 1.5s timeout
    case :inet_res.gethostbyname(charlist_host, :inet, 1500) do
      {:ok, {:hostent, _name, _aliases, :inet, _len, [ip_tuple | _]}} ->
        {:ok, ip_tuple_to_string(ip_tuple)}

      _ ->
        # Fallback to standard system resolver
        case :inet.gethostbyname(charlist_host) do
          {:ok, {:hostent, _name, _aliases, :inet, _len, [ip_tuple | _]}} ->
            {:ok, ip_tuple_to_string(ip_tuple)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ip_tuple_to_string({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp ip_tuple_to_string(other), do: inspect(other)
end
