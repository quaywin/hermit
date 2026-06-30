defmodule Hermit.Vpn.Inbound.Proxy do
  @behaviour Hermit.Vpn.Inbound
  require Logger

  @impl true
  def bootstrap(pair_id, _outbound_if, storage_dir, config) do
    proxy_name = "hermit_proxy_#{pair_id}"

    cond do
      mock?() ->
        Logger.info("Mock: Starting Proxy #{proxy_name}")
        # In mock mode, we still start the relayer to mock TCP listening
        Hermit.Vpn.Inbound.Proxy.Relayer.start_link(
          pair_id: pair_id,
          storage_dir: storage_dir,
          port: Map.get(config, "port") || Map.get(config, :port)
        )

      true ->
        Logger.info("Starting Proxy Relayer and Namespace Daemons for #{pair_id}")

        Hermit.Vpn.Inbound.Proxy.Relayer.start_link(
          pair_id: pair_id,
          storage_dir: storage_dir,
          port: Map.get(config, "port") || Map.get(config, :port)
        )
    end
  end

  @impl true
  def cleanup(pair_id, storage_dir) do
    if mock?() do
      Logger.info("Mock: Stopping Proxy for pair #{pair_id}")
      :ok
    else
      unique_suffix =
        :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 10)

      vh_name = "vh_#{unique_suffix}"

      Logger.info("Performing safety cleanup for Proxy Inbound #{pair_id}")

      # 1. Kill microsocks and tinyproxy daemons if pid files exist
      Enum.each(["microsocks.pid", "tinyproxy.pid"], fn file ->
        path = Path.join(storage_dir, file)

        if File.exists?(path) do
          case File.read(path) do
            {:ok, content} ->
              pid = String.trim(content)
              Logger.info("Killing process #{pid}")
              System.cmd("kill", [pid])
              Process.sleep(50)
              System.cmd("kill", ["-9", pid])

            _ ->
              :ok
          end

          File.rm(path)
        end
      end)

      # 2. Delete host veth interface
      System.cmd("ip", ["link", "delete", vh_name])

      # 3. Clean up config/info files
      File.rm(Path.join(storage_dir, "proxy_info.json"))
      File.rm(Path.join(storage_dir, "tinyproxy.conf"))
      File.rm(Path.join(storage_dir, "proxy.pid"))

      :ok
    end
  end

  @impl true
  def get_status(pair_id, storage_dir) do
    cond do
      mock?() ->
        if File.exists?(storage_dir), do: :running, else: :stopped

      true ->
        unique_suffix =
          :crypto.hash(:md5, pair_id) |> Base.encode16(case: :lower) |> String.slice(0, 10)

        vh_name = "vh_#{unique_suffix}"

        veth_exists =
          case System.cmd("ip", ["link", "show", vh_name]) do
            {_, 0} -> true
            _ -> false
          end

        # Read microsocks pid to verify it is running
        microsocks_running =
          case File.read(Path.join(storage_dir, "microsocks.pid")) do
            {:ok, content} ->
              pid = String.trim(content)
              File.exists?("/proc/#{pid}")

            _ ->
              false
          end

        if veth_exists and microsocks_running, do: :running, else: :stopped
    end
  end

  @impl true
  def get_network_info(pair_id, storage_dir) do
    cond do
      mock?() ->
        %{
          proxy_port: "1080 / 8080",
          proxy_socks5_url: "socks5://127.0.0.1:1080",
          proxy_http_url: "http://127.0.0.1:8080",
          proxy_status: "Running"
        }

      true ->
        case File.read(Path.join(storage_dir, "proxy_info.json")) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} ->
                socks5_port = data["socks5_port"]
                http_port = data["http_port"]

                %{
                  proxy_port: "#{socks5_port} / #{http_port}",
                  proxy_socks5_url: data["socks5_url"],
                  proxy_http_url: data["http_url"],
                  proxy_status: data["status"] || "Running"
                }

              _ ->
                default_info(pair_id)
            end

          _ ->
            default_info(pair_id)
        end
    end
  end

  # --- Internal Helpers ---

  defp default_info(_pair_id) do
    %{
      proxy_port: nil,
      proxy_socks5_url: "N/A",
      proxy_http_url: "N/A",
      proxy_status: "Offline"
    }
  end

  defp mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end
end
