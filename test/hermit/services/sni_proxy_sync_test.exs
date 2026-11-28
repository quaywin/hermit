defmodule Hermit.Services.SniProxySyncTest do
  use ExUnit.Case, async: false
  alias Hermit.Vpn.SniProxy
  alias Hermit.Vpn.DnsConfig
  alias Hermit.Dns.Rules

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Hermit.Repo)
    SniProxy.init_table()
    :ok
  end

  test "sync_all_routes/0 registers service catalog and custom rule domains in SniProxy" do
    # Create or update a DnsConfig with Netflix routed to wg_us and OpenAI to wg_sg
    _profile =
      %DnsConfig{}
      |> DnsConfig.changeset(%{
        name: "Test Sync Profile",
        upstream_dns: "1.1.1.1",
        services: %{
          "netflix" => %{"action" => "route_tunnel", "pair_id" => "wg_us"},
          "openai" => %{"action" => "route_tunnel", "pair_id" => "wg_sg"},
          "tiktok" => %{"action" => "block"}
        },
        custom_rules: [
          %{"domain" => "*.internal.mycorp.com", "action" => "route_tunnel", "value" => "wg_us"},
          %{"domain" => "tracker.com", "action" => "block", "value" => nil}
        ]
      })
      |> Hermit.Repo.insert!()

    on_exit(fn ->
      SniProxy.unregister_pair("wg_us")
      SniProxy.unregister_pair("wg_sg")
    end)

    # Sync routes
    assert :ok == SniProxy.sync_all_routes()

    # Assert wg_us has routes
    assert SniProxy.has_routes?("wg_us")
    assert SniProxy.has_routes?("wg_sg")

    # Match service domains
    assert {:ok, "wg_us"} = SniProxy.match("netflix.com")
    assert {:ok, "wg_us"} = SniProxy.match("www.netflix.com")
    assert {:ok, "wg_us"} = SniProxy.match("video.nflxvideo.net")
    assert {:ok, "wg_us"} = SniProxy.match("app.internal.mycorp.com")

    assert {:ok, "wg_sg"} = SniProxy.match("chatgpt.com")
    assert {:ok, "wg_sg"} = SniProxy.match("api.openai.com")

    # Unrouted domains
    assert :nomatch = SniProxy.match("google.com")

    # Check routed summary
    summary = SniProxy.routed_summary_for_pair("wg_us")
    assert length(summary.services) >= 1
    assert Enum.any?(summary.services, &(&1.id == "netflix"))
    assert "*.internal.mycorp.com" in summary.custom_domains
  end

  test "Dns.Rules.precompile compiles both services (block/bypass/route_tunnel) and custom_rules" do
    config = %{
      services: %{
        "tiktok" => %{"action" => "block"},
        "youtube" => %{"action" => "bypass"},
        "claude" => %{"action" => "route_tunnel", "pair_id" => "wg_us"}
      },
      custom_rules: [
        %{"domain" => "adservice.google.com", "action" => "block", "value" => nil}
      ]
    }

    compiled = Rules.precompile(config)

    # Blocked service domains
    assert {"block", nil, nil} = Rules.match("tiktok.com", compiled)
    assert {"block", nil, nil} = Rules.match("v16.tiktokcdn.com", compiled)

    # Bypassed service domains
    assert {"bypass", nil, nil} = Rules.match("youtube.com", compiled)

    # Route tunnel service domains
    assert {"route_tunnel", "wg_us", nil} = Rules.match("claude.ai", compiled)

    # Custom rule domain
    assert {"block", nil, nil} = Rules.match("adservice.google.com", compiled)
  end

  test "custom domain rules take precedence over service catalog presets" do
    _profile =
      %DnsConfig{}
      |> DnsConfig.changeset(%{
        name: "Precedence Profile",
        upstream_dns: "1.1.1.1",
        services: %{
          # Netflix defaults to wg_us
          "netflix" => %{"action" => "route_tunnel", "pair_id" => "wg_us"}
        },
        custom_rules: [
          # Custom rule overrides netflix.com to wg_uk
          %{"domain" => "*.netflix.com", "action" => "route_tunnel", "value" => "wg_uk"}
        ]
      })
      |> Hermit.Repo.insert!()

    on_exit(fn ->
      SniProxy.unregister_pair("wg_us")
      SniProxy.unregister_pair("wg_uk")
    end)

    SniProxy.sync_all_routes()

    # *.netflix.com goes to wg_uk (custom rule won)
    assert {:ok, "wg_uk"} = SniProxy.match("netflix.com")
    assert {:ok, "wg_uk"} = SniProxy.match("www.netflix.com")

    # Other Netflix CDN domains still go to wg_us (from service preset)
    assert {:ok, "wg_us"} = SniProxy.match("video.nflxvideo.net")
    assert {:ok, "wg_us"} = SniProxy.match("assets.nflxext.com")
  end

  test "sync_all_routes/0 and Rules.precompile correctly split comma-separated domains" do
    _profile =
      %DnsConfig{}
      |> DnsConfig.changeset(%{
        name: "BBC Profile",
        upstream_dns: "1.1.1.1",
        custom_rules: [
          %{"domain" => "*.bbc.co.uk, bbc.co.uk", "action" => "route_tunnel", "value" => "wg_uk"}
        ]
      })
      |> Hermit.Repo.insert!()

    on_exit(fn ->
      SniProxy.unregister_pair("wg_uk")
    end)

    SniProxy.sync_all_routes()

    # Verify both wildcard and apex domains match in SniProxy
    assert {:ok, "wg_uk"} = SniProxy.match("bbc.co.uk")
    assert {:ok, "wg_uk"} = SniProxy.match("www.bbc.co.uk")
    assert {:ok, "wg_uk"} = SniProxy.match("news.bbc.co.uk")

    # Verify Rules.precompile and Rules.match handle it
    rules_map =
      Rules.precompile([
        %{"domain" => "*.bbc.co.uk, bbc.co.uk", "action" => "route_tunnel", "value" => "wg_uk"}
      ])

    assert {"route_tunnel", "wg_uk", _} = Rules.match("bbc.co.uk", rules_map)
    assert {"route_tunnel", "wg_uk", _} = Rules.match("www.bbc.co.uk", rules_map)
  end

  test "disabled custom domain rules are ignored by Rules.precompile and SniProxy.sync_all_routes" do
    _profile =
      %DnsConfig{}
      |> DnsConfig.changeset(%{
        name: "Disabled Override Profile",
        upstream_dns: "1.1.1.1",
        services: %{
          "netflix" => %{"action" => "route_tunnel", "pair_id" => "wg_us"}
        },
        custom_rules: [
          %{
            "domain" => "*.netflix.com",
            "action" => "route_tunnel",
            "value" => "wg_uk",
            "enabled" => false
          },
          %{
            "domain" => "blocked.example.com",
            "action" => "block",
            "value" => nil,
            "enabled" => false
          },
          %{
            "domain" => "active.example.com",
            "action" => "block",
            "value" => nil,
            "enabled" => true
          }
        ]
      })
      |> Hermit.Repo.insert!()

    on_exit(fn ->
      SniProxy.unregister_pair("wg_us")
      SniProxy.unregister_pair("wg_uk")
    end)

    SniProxy.sync_all_routes()

    # Disabled override does not replace service preset in SniProxy
    assert {:ok, "wg_us"} = SniProxy.match("www.netflix.com")
    refute SniProxy.has_routes?("wg_uk")

    # Disabled rules are omitted from precompiled DNS rules while active ones remain
    compiled = Rules.precompile(Hermit.Repo.get_by!(DnsConfig, name: "Disabled Override Profile"))
    assert {"route_tunnel", "wg_us", nil} = Rules.match("www.netflix.com", compiled)
    assert {nil, nil, nil} = Rules.match("blocked.example.com", compiled)
    assert {"block", nil, nil} = Rules.match("active.example.com", compiled)
  end
end
