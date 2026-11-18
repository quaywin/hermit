defmodule HermitWeb.DnsServicesLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.VpnPair
  alias Hermit.Vpn.SniProxy

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    SniProxy.init_table()
    :ok
  end

  test "renders services catalog and switches categories", %{conn: conn} do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Default Profile",
        upstream_dns: "1.1.1.1",
        services: %{}
      })

    {:ok, view, html} = live(conn, ~p"/dns/services?profile_id=#{config.id}")

    assert html =~ "Smart DNS Services"
    assert html =~ "Netflix"
    assert html =~ "OpenAI / ChatGPT"
    assert html =~ "Claude"

    # Filter to Streaming
    html = view |> element("button[phx-value-category='streaming']") |> render_click()
    assert html =~ "Netflix"
    refute html =~ "OpenAI / ChatGPT"

    # Filter to AI
    html = view |> element("button[phx-value-category='ai']") |> render_click()
    assert html =~ "OpenAI / ChatGPT"
    refute html =~ "Netflix"
  end

  test "updates service action to route_tunnel and syncs to SniProxy", %{conn: conn} do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Streaming Profile",
        upstream_dns: "1.1.1.1",
        services: %{}
      })

    # Insert a fake active VPN pair
    {:ok, _pair} =
      Hermit.Repo.insert(%VpnPair{
        pair_id: "wg_us",
        wg_config: "[Interface]\nPrivateKey = a\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = b\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0",
        status: "running"
      })

    {:ok, view, _html} = live(conn, ~p"/dns/services?profile_id=#{config.id}")

    # Set Netflix to route via wg_us
    view
    |> render_hook("set_service_action", %{
      "service_id" => "netflix",
      "action" => "route_tunnel",
      "pair_id" => "wg_us"
    })

    # Verify SniProxy now matches Netflix domains
    assert {:ok, "wg_us"} = SniProxy.match("netflix.com")
    assert {:ok, "wg_us"} = SniProxy.match("video.nflxvideo.net")

    # Verify database updated
    updated = Hermit.Repo.get!(DnsConfig, config.id)
    assert get_in(updated.services, ["netflix", "action"]) == "route_tunnel"
    assert get_in(updated.services, ["netflix", "pair_id"]) == "wg_us"

    # Now bypass Netflix
    view
    |> render_hook("set_service_action", %{
      "service_id" => "netflix",
      "action" => "bypass"
    })

    # Verify route removed
    assert :nomatch = SniProxy.match("netflix.com")
  end
end
