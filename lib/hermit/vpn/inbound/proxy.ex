defmodule Hermit.Vpn.Inbound.Proxy do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, _storage_dir, _config) do
    proxy_name = "hermit_proxy_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Starting Proxy #{proxy_name}")
      port = Port.open({:spawn, "cat"}, [:binary])
      {:ok, port}
    else
      {:error, "Proxy inbound support is not implemented yet"}
    end
  end

  @impl true
  def cleanup(pair_id, _storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping Proxy for pair #{pair_id}")
      :ok
    else
      :ok
    end
  end

  @impl true
  def get_status(_pair_id, storage_dir) do
    if mock?() do
      if File.exists?(storage_dir), do: :running, else: :stopped
    else
      :stopped
    end
  end

  @impl true
  def get_network_info(_pair_id, _storage_dir) do
    if mock?() do
      %{
        proxy_ips: ["127.0.0.1"],
        proxy_port: 1080,
        proxy_status: "Running"
      }
    else
      %{}
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
