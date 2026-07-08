defmodule Hermit.Vpn.DnsSupervisor do
  use DynamicSupervisor
  require Logger

  @name __MODULE__

  # --- Client API ---

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: @name)
  end

  @doc """
  Dynamically starts a profile's DNS server and namespace worker.
  """
  def start_dns(profile_id) do
    Logger.info("DnsSupervisor: starting DNS worker and server for profile: #{profile_id}")

    worker_spec = {Hermit.Vpn.DnsWorker, profile_id: profile_id}
    port = 5400 + profile_id
    server_spec = {Hermit.Dns.Server, profile_id: profile_id, port: port}

    case DynamicSupervisor.start_child(@name, worker_spec) do
      {:ok, worker_pid} ->
        case DynamicSupervisor.start_child(@name, server_spec) do
          {:ok, server_pid} ->
            {:ok, {worker_pid, server_pid}}

          {:error, {:already_started, server_pid}} ->
            {:ok, {worker_pid, server_pid}}

          {:error, reason} ->
            DynamicSupervisor.terminate_child(@name, worker_pid)
            {:error, reason}
        end

      {:ok, worker_pid, _info} ->
        case DynamicSupervisor.start_child(@name, server_spec) do
          {:ok, server_pid} ->
            {:ok, {worker_pid, server_pid}}

          {:error, reason} ->
            DynamicSupervisor.terminate_child(@name, worker_pid)
            {:error, reason}
        end

      {:error, {:already_started, worker_pid}} ->
        case DynamicSupervisor.start_child(@name, server_spec) do
          {:ok, server_pid} ->
            {:ok, {worker_pid, server_pid}}

          {:error, {:already_started, server_pid}} ->
            {:ok, {worker_pid, server_pid}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the profile's DNS server and namespace worker.
  """
  def stop_dns(profile_id) do
    Logger.info("DnsSupervisor: stopping DNS components for profile: #{profile_id}")

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, profile_id}) do
      [{server_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, server_pid)

      [] ->
        :ok
    end

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_worker, profile_id}) do
      [{worker_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, worker_pid)

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Restarts only the DNS server component for a profile, keeping the worker (Tailscale node) running.
  """
  def restart_dns_server(profile_id) do
    Logger.info("DnsSupervisor: restarting DNS server (only) for profile: #{profile_id}")

    case Registry.lookup(Hermit.Vpn.Registry, {:dns_server, profile_id}) do
      [{server_pid, _}] ->
        DynamicSupervisor.terminate_child(@name, server_pid)

      [] ->
        :ok
    end

    port = 5400 + profile_id
    server_spec = {Hermit.Dns.Server, profile_id: profile_id, port: port}

    case DynamicSupervisor.start_child(@name, server_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
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
