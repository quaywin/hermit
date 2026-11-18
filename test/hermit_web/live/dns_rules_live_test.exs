defmodule HermitWeb.DnsRulesLiveTest do
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

  test "renders custom rules page, adds and deletes rules", %{conn: conn} do
    _config = DnsConfig.get_global_config()

    {:ok, _pair} =
      Hermit.Repo.insert(%VpnPair{
        pair_id: "wg_sg",
        wg_config: "[Interface]\nPrivateKey = a\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = b\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0",
        status: "running"
      })

    {:ok, view, html} = live(conn, ~p"/dns/rules")

    assert html =~ "Custom Domain Rules"
    assert html =~ "No custom domain rules configured yet"

    # Open add modal
    view |> element("button", "Add Domain Rule") |> render_click()

    # Add a custom rule routing *.internal.corp to wg_sg
    view
    |> form("#modal-add-custom-rule-form", %{
      "domain" => "*.internal.corp",
      "action" => "route_tunnel",
      "value" => "wg_sg"
    })
    |> render_submit()

    # Assert SniProxy matches the custom wildcard domain
    assert {:ok, "wg_sg"} = SniProxy.match("api.internal.corp")
    assert {:ok, "wg_sg"} = SniProxy.match("internal.corp")

    # Verify rule appears in UI table
    updated_html = render(view)
    assert updated_html =~ "internal.corp"
    assert updated_html =~ "Route Tunnel"
    assert updated_html =~ "wg_sg"

    # Delete rule
    view
    |> element("button[phx-value-domain='*.internal.corp']")
    |> render_click()

    # Assert SniProxy no longer matches
    assert :nomatch = SniProxy.match("api.internal.corp")
  end
end
