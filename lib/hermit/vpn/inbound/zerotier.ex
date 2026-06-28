defmodule Hermit.Vpn.Inbound.ZeroTier do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, _storage_dir, _config) do
    zt_name = "hermit_zt_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Starting ZeroTier #{zt_name}")
      port = Port.open({:spawn, "cat"}, [:binary])
      {:ok, port}
    else
      {:error, "ZeroTier inbound support is not implemented yet"}
    end
  end

  @impl true
  def cleanup(pair_id, _storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping ZeroTier for pair #{pair_id}")
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
        zt_ips: ["10.147.20.10"],
        zt_network_id: "8056c2e21c000001",
        zt_status: "OK"
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
