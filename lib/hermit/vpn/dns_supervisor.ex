defmodule Hermit.Vpn.DnsSupervisor do
  use DynamicSupervisor
  require Logger

  @name __MODULE__

  # --- Client API ---

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: @name)
  end

  @doc """
  Dynamically starts an endpoint's DNS server and namespace worker.
  """
  def start_dns(endpoint_id, inbound_profile_id \\ nil) do
    Logger.info(
      "DnsSupervisor: starting DNS worker and server for endpoint: #{endpoint_id} (inbound_profile: #{inbound_profile_id})"
    )

    worker_spec =
      {Hermit.Vpn.DnsWorker, endpoint_id: endpoint_id, inbound_profile_id: inbound_profile_id}

    port = 5400 + endpoint_id

    server_spec =
      {Hermit.Dns.Server,
       endpoint_id: endpoint_id, inbound_profile_id: inbound_profile_id, port: port}

    # Only start DnsWorker (namespace / Tailscale) if inbound_profile_id is provided (Tailscale endpoint)
    case start_worker_if_needed(inbound_profile_id, worker_spec, endpoint_id) do
      {:ok, worker_pid} ->
        case DynamicSupervisor.start_child(@name, server_spec) do
          {:ok, server_pid} ->
            {:ok, {worker_pid, server_pid}}

          {:error, {:already_started, server_pid}} ->
            {:ok, {worker_pid, server_pid}}

          {:error, reason} ->
            if worker_pid, do: DynamicSupervisor.terminate_child(@name, worker_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_worker_if_needed(nil, _worker_spec, _endpoint_id), do: {:ok, nil}

  defp start_worker_if_needed(_inbound_profile_id, worker_spec, _endpoint_id) do
    case DynamicSupervisor.start_child(@name, worker_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops the endpoint's DNS server and namespace worker.
  """
  def stop_dns(endpoint_id) do
    Logger.info("DnsSupervisor: stopping DNS components for endpoint: #{endpoint_id}")

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
      [{server_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, server_pid)
        wait_until_unregistered({:dns_server, endpoint_id})

      [] ->
        :ok
    end

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, endpoint_id}) do
      [{worker_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, worker_pid)
        wait_until_unregistered({:dns_worker, endpoint_id})

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Restarts only the DNS server component for an endpoint, keeping the worker (Tailscale node) running.
  """
  def restart_dns_server(endpoint_id) do
    Logger.info("DnsSupervisor: restarting DNS server (only) for endpoint: #{endpoint_id}")

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, endpoint_id}) do
      [{server_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, server_pid)
        wait_until_unregistered({:dns_server, endpoint_id})

      [] ->
        :ok
    end

    port = 5400 + endpoint_id
    endpoint = Hermit.Repo.get(Hermit.Vpn.DnsEndpoint, endpoint_id)
    inbound_profile_id = endpoint && endpoint.inbound_profile_id

    server_spec =
      {Hermit.Dns.Server,
       endpoint_id: endpoint_id, inbound_profile_id: inbound_profile_id, port: port}

    case DynamicSupervisor.start_child(@name, server_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_until_unregistered(key, retries \\ 20) do
    case Registry.lookup(Hermit.Vpn.Registry, key) do
      [] ->
        :ok

      _ ->
        if retries > 0 do
          Process.sleep(50)
          wait_until_unregistered(key, retries - 1)
        else
          {:error, :timeout}
        end
    end
  end

  # --- Callbacks ---

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 1
    )
  end
end
