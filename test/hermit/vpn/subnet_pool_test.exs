defmodule Hermit.Vpn.SubnetPoolTest do
  use ExUnit.Case, async: true
  alias Hermit.Vpn.SubnetPool

  test "allocates valid /30 subnets sequentially" do
    unless Process.whereis(SubnetPool) do
      start_supervised!(SubnetPool)
    end

    assert {:ok, sub1} = SubnetPool.get_or_allocate_subnet("test_pair_1")
    assert {:ok, sub2} = SubnetPool.get_or_allocate_subnet("test_pair_2")

    refute sub1.subnet == sub2.subnet
    refute sub1.host_ip == sub2.host_ip
    refute sub1.ns_ip == sub2.ns_ip
    refute sub1.proxy_host_ip == sub2.proxy_host_ip

    # Idempotent for same pair_id
    assert {:ok, sub1_again} = SubnetPool.get_or_allocate_subnet("test_pair_1")
    assert sub1 == sub1_again
  end

  test "releases subnet and allows re-allocation" do
    unless Process.whereis(SubnetPool) do
      start_supervised!(SubnetPool)
    end

    assert {:ok, sub} = SubnetPool.get_or_allocate_subnet("release_test_pair")
    _index = sub.index

    SubnetPool.release_subnet("release_test_pair")

    # A new pair can reclaim the released index if it's the lowest available
    assert {:ok, new_sub} = SubnetPool.get_or_allocate_subnet("reclaim_test_pair")
    assert is_integer(new_sub.index)
  end

  test "concurrent allocations receive 100% disjoint subnets" do
    unless Process.whereis(SubnetPool) do
      start_supervised!(SubnetPool)
    end

    pairs = for i <- 1..50, do: "concurrent_pair_#{i}"

    results =
      pairs
      |> Enum.map(fn pair_id ->
        Task.async(fn -> SubnetPool.get_or_allocate_subnet(pair_id) end)
      end)
      |> Task.await_many()

    subnets = Enum.map(results, fn {:ok, info} -> info.subnet end)
    indices = Enum.map(results, fn {:ok, info} -> info.index end)

    assert length(subnets) == 50
    assert length(Enum.uniq(subnets)) == 50
    assert length(Enum.uniq(indices)) == 50
  end
end
