defmodule Hermit.Dns.BlocklistTest do
  use ExUnit.Case, async: true
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
end
