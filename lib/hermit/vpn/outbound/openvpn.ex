defmodule Hermit.Vpn.Outbound.OpenVPN do
  @behaviour Hermit.Vpn.Outbound
  require Logger

  @impl true
  def bootstrap(pair_id, _storage_dir, _config) do
    ovpn_name = "hermit_ovpn_#{pair_id}"

    if mock?() do
      Logger.info("Mock: Starting OpenVPN #{ovpn_name}")
      {:ok, "tun0"}
    else
      {:error, "OpenVPN outbound support is not implemented yet"}
    end
  end

  @impl true
  def cleanup(pair_id, _storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping OpenVPN for pair #{pair_id}")
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
  def get_metrics(_pair_id, storage_dir) do
    if mock?() do
      if File.exists?(storage_dir) do
        {:ok, %{bytes_received: 2048, bytes_sent: 4096}}
      else
        {:error, :not_found}
      end
    else
      :error
    end
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
