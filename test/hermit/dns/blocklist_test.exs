defmodule Hermit.Dns.BlocklistTest do
  use ExUnit.Case, async: true
  alias Hermit.Dns.Server

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

    assert Server.match_ets_blocklist?("doubleclick.net", table)
    # Case insensitivity test
    assert Server.match_ets_blocklist?("DOUBLECLICK.NET", table)
    refute Server.match_ets_blocklist?("google.com", table)
  end

  test "match_ets_blocklist? returns true for subdomain match", %{table: table} do
    :ets.insert(table, {"doubleclick.net", true})

    assert Server.match_ets_blocklist?("ads.doubleclick.net", table)
    assert Server.match_ets_blocklist?("a.b.ads.doubleclick.net", table)
    refute Server.match_ets_blocklist?("not-doubleclick.net", table)
    refute Server.match_ets_blocklist?("doubleclick.net.secure.com", table)
  end

  test "match_ets_blocklist? handles domains with less than 2 parts gracefully", %{table: table} do
    :ets.insert(table, {"localhost", true})

    assert Server.match_ets_blocklist?("localhost", table)
    refute Server.match_ets_blocklist?("local", table)
  end

  test "check if real facebook domains are blocked" do
    # Wait for blocklists to load since they load asynchronously on startup
    Process.sleep(2000)

    IO.inspect(Server.match_ets_blocklist?("facebook.com", :adguard_blocklist),
      label: "facebook.com adguard"
    )

    IO.inspect(Server.match_ets_blocklist?("facebook.com", :goodbyeads_blocklist),
      label: "facebook.com goodbyeads"
    )

    IO.inspect(Server.match_ets_blocklist?("www.facebook.com", :adguard_blocklist),
      label: "www.facebook.com adguard"
    )

    IO.inspect(Server.match_ets_blocklist?("www.facebook.com", :goodbyeads_blocklist),
      label: "www.facebook.com goodbyeads"
    )

    IO.inspect(Server.match_ets_blocklist?("fbcdn.net", :adguard_blocklist),
      label: "fbcdn.net adguard"
    )

    IO.inspect(Server.match_ets_blocklist?("fbcdn.net", :goodbyeads_blocklist),
      label: "fbcdn.net goodbyeads"
    )

    IO.inspect(Server.match_ets_blocklist?("scontent.xx.fbcdn.net", :adguard_blocklist),
      label: "scontent.xx.fbcdn.net adguard"
    )

    IO.inspect(Server.match_ets_blocklist?("scontent.xx.fbcdn.net", :goodbyeads_blocklist),
      label: "scontent.xx.fbcdn.net goodbyeads"
    )

    IO.inspect(Server.match_ets_blocklist?("graph.facebook.com", :adguard_blocklist),
      label: "graph.facebook.com adguard"
    )

    IO.inspect(Server.match_ets_blocklist?("graph.facebook.com", :goodbyeads_blocklist),
      label: "graph.facebook.com goodbyeads"
    )
  end
end
