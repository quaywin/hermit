defmodule Hermit.Vpn.PortAllocator do
  @moduledoc """
  Helper to allocate free ports within the range mapped by Docker Bridge mode.
  """
  require Logger

  @start_port 10000
  @end_port 10199

  @doc """
  Finds two consecutive free TCP ports (P and P + 1) in the range #{@start_port}..#{@end_port}.
  Returns `{:ok, socks_port, http_port}` or `{:error, :no_ports_available}`.
  """
  def allocate_free_ports do
    # Search in steps of 2 to keep them clean, or sequentially
    result =
      Enum.find_value(@start_port..(@end_port - 1), fn port ->
        if port_free?(port) and port_free?(port + 1) do
          {port, port + 1}
        else
          nil
        end
      end)

    case result do
      {socks, http} ->
        Logger.info("PortAllocator: Allocated ports SOCKS5=#{socks}, HTTP=#{http}")
        {:ok, socks, http}

      nil ->
        Logger.error("PortAllocator: No free ports available in range #{@start_port}..#{@end_port}")
        {:error, :no_ports_available}
    end
  end

  defp port_free?(port) do
    # Try to listen on the port briefly to see if it is in use
    opts = [:binary, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, opts) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
