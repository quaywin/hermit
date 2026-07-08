defmodule HermitWeb.DnsProfileLiveTest do
  use HermitWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Hermit.Vpn.DnsConfig

  setup do
    # Tạo profile DNS mặc định
    {:ok, default_profile} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Default DNS Profile",
        upstream_dns: "1.1.1.1, 8.8.8.8",
        custom_rules: []
      })

    {:ok, default_profile: default_profile}
  end

  test "renders DNS Profiles page and lists profiles", %{conn: conn, default_profile: _profile} do
    {:ok, _view, html} = live(conn, ~p"/dns")

    assert html =~ "DNS Server Profiles"
    assert html =~ "Default DNS Profile"

    # Verify detail displays selected profile info
    assert html =~ "DNS Profile: Default DNS Profile"
    assert html =~ "Upstream DNS Servers"
    assert html =~ "Custom Domain Routing Rules"
  end

  test "creates new DNS Profile using modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dns")

    # Open modal
    assert view |> element("button", "Create DNS Profile") |> render_click() =~ "Create DNS Profile"

    # Submit form
    html =
      view
      |> form("form[phx-submit=save_profile]", %{
        "dns_config" => %{
          "name" => "Kids Filter",
          "upstream_dns" => "1.1.1.3, 8.8.8.3"
        }
      })
      |> render_submit()

    assert html =~ "DNS Profile created successfully."
    assert html =~ "Kids Filter"
    assert html =~ "DNS Profile: Kids Filter"
  end

  test "toggles filter settings dynamically", %{conn: conn, default_profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dns?id=#{profile.id}")

    # Toggle Ads Blocking
    html = view |> element("button[phx-click=toggle_block_ads]") |> render_click()
    assert html =~ "Ads/Trackers blocking enabled!"
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:block_ads) == true

    # Toggle GoodbyeAds
    html = view |> element("button[phx-click=toggle_block_goodbyeads]") |> render_click()
    assert html =~ "GoodbyeAds blocking enabled!"
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:block_goodbyeads) == true

    # Toggle Adult Blocking
    html = view |> element("button[phx-click=toggle_block_adult]") |> render_click()
    assert html =~ "Adult content blocking enabled!"
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:block_adult) == true
  end

  test "saves upstream DNS configurations", %{conn: conn, default_profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dns?id=#{profile.id}")

    html =
      view
      |> form("form[phx-submit=save_upstream_dns]", %{
        "upstream_dns" => "9.9.9.9, 149.112.112.112"
      })
      |> render_submit()

    assert html =~ "Upstream DNS servers updated."
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:upstream_dns) == "9.9.9.9, 149.112.112.112"
  end

  test "manages custom routing rules (add & delete)", %{conn: conn, default_profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dns?id=#{profile.id}")

    # Add custom rule: block
    html =
      view
      |> form("form[phx-submit=add_custom_rule]", %{
        "domain" => "ad.example.com",
        "action" => "block"
      })
      |> render_submit()

    assert html =~ "Custom rule for ad.example.com added."
    assert html =~ "ad.example.com"
    assert html =~ "block"

    # Add custom rule: redirect
    view |> element("select[name=action]") |> render_change(%{"action" => "redirect"})
    html =
      view
      |> form("form[phx-submit=add_custom_rule]", %{
        "domain" => "local-dev.org",
        "action" => "redirect",
        "value" => "192.168.10.20"
      })
      |> render_submit()

    assert html =~ "Custom rule for local-dev.org added."
    assert html =~ "local-dev.org"
    assert html =~ "redirect"
    assert html =~ "192.168.10.20"

    # Delete custom rule
    html = view |> element("button[phx-value-domain='ad.example.com']") |> render_click()
    assert html =~ "Custom rule for ad.example.com deleted."

    # Verify directly in DB
    db_config = Hermit.Repo.get!(DnsConfig, profile.id)
    assert Enum.find(db_config.custom_rules, &(&1["domain"] == "ad.example.com")) == nil
    assert Enum.find(db_config.custom_rules, &(&1["domain"] == "local-dev.org")) != nil
  end

  test "supports renaming the DNS profile inline", %{conn: conn, default_profile: profile} do
    {:ok, view, html} = live(conn, ~p"/dns?id=#{profile.id}")
    assert html =~ "DNS Profile: Default DNS Profile"

    # Start editing
    html = view |> element("button[phx-click=start_edit_name]") |> render_click()
    assert html =~ "id=\"edit-profile-name-form\""

    # Cancel editing
    html = view |> element("button[phx-click=cancel_edit_name]") |> render_click()
    assert html =~ "DNS Profile: Default DNS Profile"
    refute html =~ "id=\"edit-profile-name-form\""

    # Start editing again and save
    _ = view |> element("button[phx-click=start_edit_name]") |> render_click()
    html =
      view
      |> form("#edit-profile-name-form", %{
        "dns_config" => %{"name" => "Production DNS Filter"}
      })
      |> render_submit()

    assert html =~ "DNS Profile renamed successfully."
    assert html =~ "DNS Profile: Production DNS Filter"
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:name) == "Production DNS Filter"
  end

  test "supports pausing and resuming query logs streaming", %{conn: conn, default_profile: profile} do
    {:ok, view, html} = live(conn, ~p"/dns?id=#{profile.id}")
    assert html =~ "Pause Stream"
    refute html =~ "(Paused)"

    # Pause logs
    html = view |> element("button[phx-click=toggle_pause_logs]") |> render_click()
    assert html =~ "Resume Stream"
    assert html =~ "(Paused)"

    # Broadcast log while paused -> should NOT appear
    log1 = %{
      pair_id: "1",
      client_ip: "10.0.0.5",
      domain: "paused-test.com",
      qtype: "A",
      status: "resolved",
      answer: "1.1.1.1",
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs_profile:#{profile.id}", {:dns_log, log1})
    Process.sleep(50)
    refute render(view) =~ "paused-test.com"

    # Resume logs
    html = view |> element("button[phx-click=toggle_pause_logs]") |> render_click()
    assert html =~ "Pause Stream"
    refute html =~ "(Paused)"

    # Broadcast log while resumed -> should appear
    log2 = %{
      pair_id: "1",
      client_ip: "10.0.0.5",
      domain: "active-test.com",
      qtype: "A",
      status: "resolved",
      answer: "1.1.1.1",
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs_profile:#{profile.id}", {:dns_log, log2})
    Process.sleep(50)
    assert render(view) =~ "active-test.com"
  end
end
