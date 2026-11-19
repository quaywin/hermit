defmodule Hermit.Dns.BlocklistTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Hermit.Dns.Filter

  setup do
    table = :test_blocklist
    # Create a temporary table for testing
    if :ets.info(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table])
    else
      :ets.delete_all_objects(table)
    end

    {:ok, table: table}
  end

  test "match_ets_blocklist? returns true for exact domain match", %{table: table} do
    :ets.insert(table, {"doubleclick.net", true})

    assert Filter.match_ets_blocklist?("doubleclick.net", table)
    # Case insensitivity test
    assert Filter.match_ets_blocklist?("DOUBLECLICK.NET", table)
    refute Filter.match_ets_blocklist?("google.com", table)
  end

  test "match_ets_blocklist? returns true for subdomain match", %{table: table} do
    :ets.insert(table, {"doubleclick.net", true})

    assert Filter.match_ets_blocklist?("ads.doubleclick.net", table)
    assert Filter.match_ets_blocklist?("a.b.ads.doubleclick.net", table)
    refute Filter.match_ets_blocklist?("not-doubleclick.net", table)
    refute Filter.match_ets_blocklist?("doubleclick.net.secure.com", table)
  end

  test "match_ets_blocklist? handles domains with less than 2 parts gracefully", %{table: table} do
    :ets.insert(table, {"localhost", true})

    assert Filter.match_ets_blocklist?("localhost", table)
    refute Filter.match_ets_blocklist?("local", table)
  end

  test "check if real facebook domains are blocked" do
    refute Filter.match_ets_blocklist?("facebook.com", :adguard_blocklist)
    refute Filter.match_ets_blocklist?("facebook.com", :goodbyeads_blocklist)
    refute Filter.match_ets_blocklist?("www.facebook.com", :adguard_blocklist)
    refute Filter.match_ets_blocklist?("www.facebook.com", :goodbyeads_blocklist)
    refute Filter.match_ets_blocklist?("fbcdn.net", :adguard_blocklist)
    refute Filter.match_ets_blocklist?("fbcdn.net", :goodbyeads_blocklist)
    refute Filter.match_ets_blocklist?("scontent.xx.fbcdn.net", :adguard_blocklist)
    refute Filter.match_ets_blocklist?("scontent.xx.fbcdn.net", :goodbyeads_blocklist)
    refute Filter.match_ets_blocklist?("graph.facebook.com", :adguard_blocklist)
    refute Filter.match_ets_blocklist?("graph.facebook.com", :goodbyeads_blocklist)
  end

  test "match_any_ets_blocklist_cached? matches bitmask-encoded set entries" do
    if :ets.info(:dns_blocklist_entries) == :undefined do
      :ets.new(:dns_blocklist_entries, [:set, :public, :named_table, read_concurrency: true])
    end

    if :ets.info(:dns_bloom_filter) != :undefined do
      :ets.delete(:dns_bloom_filter, 101)
      :ets.delete(:dns_bloom_filter, 102)
    end

    # Use IDs 101 and 102 to avoid collision with loaded blocklists
    # List 101: 1 <<< 100
    # List 102: 1 <<< 101
    mask1 = 1 <<< 100
    mask2 = 1 <<< 101
    mask_shared = mask1 ||| mask2

    :ets.insert(:dns_blocklist_entries, [
      {"bitmask-test1.com", mask1},
      {"bitmask-test2.com", mask2},
      {"bitmask-shared.com", mask_shared}
    ])

    # Querying list 101
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test1.com", [101]) == 101
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test2.com", [101]) == nil
    assert Filter.match_any_ets_blocklist_cached?("bitmask-shared.com", [101]) == 101

    # Querying list 102
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test1.com", [102]) == nil
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test2.com", [102]) == 102
    assert Filter.match_any_ets_blocklist_cached?("bitmask-shared.com", [102]) == 102

    # Querying both lists [101, 102]
    assert Filter.match_any_ets_blocklist_cached?("sub.bitmask-test1.com", [101, 102]) == 101
    assert Filter.match_any_ets_blocklist_cached?("sub.bitmask-test2.com", [101, 102]) == 102
    assert Filter.match_any_ets_blocklist_cached?("clean-domain-random.com", [101, 102]) == nil

    # Test unloading list 101 cleans entries and clears bitmask without deleting shared domains
    Hermit.Dns.BlocklistLoader.unload_blocklist(101)
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test1.com", [101, 102]) == nil
    assert Filter.match_any_ets_blocklist_cached?("bitmask-shared.com", [102]) == 102
    assert Filter.match_any_ets_blocklist_cached?("bitmask-test2.com", [102]) == 102
  end
end
