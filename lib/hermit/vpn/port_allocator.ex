defmodule Hermit.Vpn.PortAllocator do
  @moduledoc """
  Stateful Port Coordinator managing free TCP ports within the range 10000..29999.
  Tracks port reservations, monitors owner processes, and prevents Time-of-Check to Time-of-Use (TOCTOU)
  race conditions during concurrent VPN tunnel pair startups.
  """
  use GenServer
  require Logger

  @start_port 10000
  @end_port 29999

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Finds two consecutive free TCP ports (P and P + 1) in the range #{@start_port}..#{@end_port}.
  Reservations are automatically held for `owner_pid` (default `self()`).
  If `owner_pid` terminates, the reserved ports are automatically released.
  Returns `{:ok, socks_port, http_port}` or `{:error, :no_ports_available}`.
  """
  def allocate_free_ports(owner_pid \\ nil) do
    target_pid = owner_pid || self()
    GenServer.call(__MODULE__, {:allocate_ports, target_pid}, 15_000)
  end

  @doc """
  Explicitly releases a list of ports back to the allocator pool.
  """
  def release_ports(ports) when is_list(ports) do
    GenServer.cast(__MODULE__, {:release_ports, ports})
  end

  def release_ports(port) when is_integer(port), do: release_ports([port])

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{allocated: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:allocate_ports, owner_pid}, _from, state) do
    result =
      Enum.find_value(@start_port..(@end_port - 1), fn port ->
        if not Map.has_key?(state.allocated, port) and
             not Map.has_key?(state.allocated, port + 1) and
             port_free?(port) and
             port_free?(port + 1) do
          {port, port + 1}
        else
          nil
        end
      end)

    case result do
      {socks, http} ->
        ref = Process.monitor(owner_pid)

        new_allocated =
          state.allocated
          |> Map.put(socks, {owner_pid, ref})
          |> Map.put(http, {owner_pid, ref})

        new_monitors = Map.put(state.monitors, ref, [socks, http])
        new_state = %{state | allocated: new_allocated, monitors: new_monitors}

        Logger.info(
          "PortAllocator: Reserved ports SOCKS5=#{socks}, HTTP=#{http} for #{inspect(owner_pid)}"
        )

        {:reply, {:ok, socks, http}, new_state}

      nil ->
        Logger.error(
          "PortAllocator: No free ports available in range #{@start_port}..#{@end_port}"
        )

        {:reply, {:error, :no_ports_available}, state}
    end
  end

  @impl true
  def handle_cast({:release_ports, ports}, state) do
    new_state = do_release_ports(state, ports)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      ports ->
        Logger.info(
          "PortAllocator: Process #{inspect(pid)} died, auto-releasing ports #{inspect(ports)}"
        )

        new_state = do_release_ports(state, ports, ref)
        {:noreply, new_state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Helpers ---

  defp do_release_ports(state, ports, specific_ref \\ nil) do
    new_allocated = Map.drop(state.allocated, ports)

    new_monitors =
      if specific_ref do
        Map.delete(state.monitors, specific_ref)
      else
        Enum.reduce(ports, state.monitors, fn port, acc ->
          case Map.get(state.allocated, port) do
            {_pid, ref} ->
              remaining = (Map.get(acc, ref, []) -- [port])
              if remaining == [] do
                Process.demonitor(ref, [:flush])
                Map.delete(acc, ref)
              else
                Map.put(acc, ref, remaining)
              end

            nil ->
              acc
          end
        end)
      end

    %{state | allocated: new_allocated, monitors: new_monitors}
  end

  defp port_free?(port) do
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
