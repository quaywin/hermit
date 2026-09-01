defmodule Hermit.Vpn.DnsDdnsResolver do
  @moduledoc """
  Background GenServer worker that periodically resolves DDNS hostnames configured
  for DNS Endpoints (Port 53 Matcher) and maintains an in-memory ETS mapping
  of client WAN IPs to DNS Endpoint IDs.
  """
  use GenServer
  import Ecto.Query
  alias Hermit.Vpn.DnsEndpoint
  require Logger

  @table :ddns_client_ip_map

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up an endpoint_id by client IP address string (e.g., "203.0.113.50").
  Returns endpoint_id or nil.
  """
  def lookup_endpoint(client_ip) when is_binary(client_ip) do
    try do
      case :ets.lookup(@table, {:ip, client_ip}) do
        [{_, endpoint_id}] ->
          endpoint_id

        [] ->
          case :ets.match_object(@table, {:unfiltered_endpoint, :_}) do
            [{_, ep_id} | _] ->
              ep_id

            [] ->
              if client_ip in ["127.0.0.1", "::1"] do
                case :ets.match_object(@table, {{:endpoint, :_}, :_}) do
                  [{{:endpoint, ep_id}, _} | _] -> ep_id
                  _ -> nil
                end
              else
                nil
              end
          end
      end
    rescue
      ArgumentError -> nil
    end
  end

  def lookup_endpoint(_), do: nil

  @doc """
  Returns a map of %{endpoint_id => %{ip: ip_string, hostname: hostname, enable_ddns_filter: boolean}} for UI rendering.
  """
  def get_resolved_ddns_map do
    try do
      :ets.match_object(@table, {{:endpoint, :_}, :_})
      |> Enum.map(fn {{:endpoint, endpoint_id}, data} -> {endpoint_id, data} end)
      |> Enum.into(%{})
    rescue
      ArgumentError -> %{}
    end
  end

  @doc """
  Triggers an immediate background sync of DDNS hostnames.
  """
  def trigger_sync do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :resolve_all)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Initial resolve on boot, then periodic check every 60 seconds
    send(self(), :resolve_all)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:resolve_all, state) do
    perform_resolutions()
    Process.send_after(self(), :resolve_all, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:resolve_all, state) do
    perform_resolutions()
    {:noreply, state}
  end

  # --- Helper Functions ---

  defp perform_resolutions do
    # Clear previous unfiltered endpoints
    :ets.match_delete(@table, {:unfiltered_endpoint, :_})

    endpoints =
      try do
        Hermit.Repo.all(
          from(e in DnsEndpoint,
            where: e.enabled == true and not is_nil(e.ddns_hostname) and e.ddns_hostname != ""
          )
        )
      rescue
        _ -> []
      end

    Enum.each(endpoints, fn endpoint ->
      hostname = String.trim(endpoint.ddns_hostname)
      enable_filter = Map.get(endpoint, :enable_ddns_filter) != false

      if not enable_filter do
        :ets.insert(@table, {:unfiltered_endpoint, endpoint.id})
      end

      case resolve_hostname(hostname) do
        {:ok, ip_str} ->
          :ets.insert(@table, {{:ip, ip_str}, endpoint.id})

          :ets.insert(
            @table,
            {{:endpoint, endpoint.id},
             %{ip: ip_str, hostname: hostname, enable_ddns_filter: enable_filter}}
          )

        {:error, reason} ->
          :ets.insert(
            @table,
            {{:endpoint, endpoint.id},
             %{ip: "Resolving...", hostname: hostname, enable_ddns_filter: enable_filter}}
          )

          Logger.debug(
            "DnsDdnsResolver: Failed to resolve #{hostname} for endpoint #{endpoint.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp resolve_hostname(hostname) when is_binary(hostname) do
    hostname = String.trim(hostname)

    case :inet.parse_address(String.to_charlist(hostname)) do
      {:ok, ip_tuple} ->
        {:ok, :inet.ntoa(ip_tuple) |> to_string()}

      {:error, _} ->
        char_host = String.to_charlist(hostname)

        case :inet.gethostbyname(char_host, :inet, 1000) do
          {:ok, {:hostent, _name, _aliases, :inet, 4, [ip_tuple | _]}} ->
            ip_str = :inet.ntoa(ip_tuple) |> to_string()
            {:ok, ip_str}

          other ->
            {:error, other}
        end
    end
  end
end
