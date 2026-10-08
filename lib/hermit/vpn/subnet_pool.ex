defmodule Hermit.Vpn.SubnetPool do
  @moduledoc """
  Stateful IPv4 Subnet Coordinator managing /30 subnets within the 10.200.0.0/16 address space.
  Replaces fragile hash-based subnet generation (phash2) with safe, deterministic, sequential
  allocation capable of supporting up to 16,380 completely isolated VPN pairs without collision.
  """
  use GenServer
  require Logger

  @max_subnets 16_380

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves or allocates a collision-free /30 subnet for the specified `pair_id`.
  Returns `{:ok, subnet_info}` where `subnet_info` contains:
  - `:index` - Assigned integer index (1..#{@max_subnets})
  - `:subnet` - "10.200.b.c/30"
  - `:host_ip` - "10.200.b.(c+1)/30"
  - `:gateway_ip` - "10.200.b.(c+1)"
  - `:ns_ip` - "10.200.b.(c+2)"
  - `:local_ip` - "10.200.b.(c+2)/30"
  - `:proxy_host_ip` - "172.29.b.(c+1)"
  - `:proxy_ns_ip` - "172.29.b.(c+2)"
  """
  def get_or_allocate_subnet(pair_id) do
    GenServer.call(__MODULE__, {:get_or_allocate, to_string(pair_id)}, 15_000)
  end

  @doc """
  Releases the subnet allocation for `pair_id` back to the free pool.
  """
  def release_subnet(pair_id) do
    GenServer.cast(__MODULE__, {:release, to_string(pair_id)})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{pair_to_index: %{}, index_to_pair: %{}}}
  end

  @impl true
  def handle_call({:get_or_allocate, pair_id}, _from, state) do
    case Map.get(state.pair_to_index, pair_id) do
      index when is_integer(index) ->
        {:reply, {:ok, format_subnet(index)}, state}

      nil ->
        case find_first_free_index(state.index_to_pair) do
          {:ok, index} ->
            new_pair_to_index = Map.put(state.pair_to_index, pair_id, index)
            new_index_to_pair = Map.put(state.index_to_pair, index, pair_id)
            new_state = %{state | pair_to_index: new_pair_to_index, index_to_pair: new_index_to_pair}

            Logger.info("SubnetPool: Allocated subnet index #{index} for pair #{pair_id}")
            {:reply, {:ok, format_subnet(index)}, new_state}

          {:error, :pool_exhausted} ->
            Logger.error("SubnetPool: Exhausted all #{@max_subnets} subnets!")
            {:reply, {:error, :subnets_exhausted}, state}
        end
    end
  end

  @impl true
  def handle_cast({:release, pair_id}, state) do
    case Map.get(state.pair_to_index, pair_id) do
      index when is_integer(index) ->
        Logger.info("SubnetPool: Released subnet index #{index} for pair #{pair_id}")
        new_pair_to_index = Map.delete(state.pair_to_index, pair_id)
        new_index_to_pair = Map.delete(state.index_to_pair, index)
        {:noreply, %{state | pair_to_index: new_pair_to_index, index_to_pair: new_index_to_pair}}

      nil ->
        {:noreply, state}
    end
  end

  # --- Helpers ---

  def format_subnet(index) when is_integer(index) and index >= 1 do
    offset = (index - 1) * 4
    b = div(offset, 256)
    c = rem(offset, 256)

    subnet = "10.200.#{b}.#{c}/30"
    host_ip = "10.200.#{b}.#{c + 1}/30"
    gateway_ip = "10.200.#{b}.#{c + 1}"
    ns_ip = "10.200.#{b}.#{c + 2}"
    local_ip = "10.200.#{b}.#{c + 2}/30"
    proxy_host_ip = "172.29.#{b}.#{c + 1}"
    proxy_ns_ip = "172.29.#{b}.#{c + 2}"

    %{
      index: index,
      subnet: subnet,
      host_ip: host_ip,
      gateway_ip: gateway_ip,
      ns_ip: ns_ip,
      local_ip: local_ip,
      proxy_host_ip: proxy_host_ip,
      proxy_ns_ip: proxy_ns_ip
    }
  end

  defp find_first_free_index(index_to_pair) do
    case Enum.find(1..@max_subnets, fn idx -> not Map.has_key?(index_to_pair, idx) end) do
      nil -> {:error, :pool_exhausted}
      idx -> {:ok, idx}
    end
  end
end
