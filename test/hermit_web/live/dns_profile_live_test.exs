defmodule HermitWeb.DnsProfileLiveTest do
  use HermitWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Hermit.Vpn.DnsConfig

  setup do
    {:ok, default_profile} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Default DNS Profile",
        upstream_dns: "76.76.2.2, 76.76.10.2",
        custom_rules: []
      })

    {:ok, default_profile: default_profile}
  end

  test "renders DNS Profiles page and lists profiles", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dns")

    assert html =~ "DNS Server Profiles"
    assert html =~ "Default DNS Profile"

    assert html =~ "DNS Profile: Default DNS Profile"
    assert html =~ "DNS Resolver &amp; Filtering"
    assert html =~ "Routing &amp; Domain Policies"
    assert html =~ "Services Catalog"
  end

  test "creates new DNS Profile using modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dns")

    assert view |> element("button", "Create DNS Profile") |> render_click() =~
             "Create DNS Profile"

    html =
      view
      |> form("form[phx-submit=save_profile]", %{
        "dns_config" => %{
          "name" => "Kids Filter",
          "upstream_dns" => "76.76.2.5, 76.76.10.5"
        }
      })
      |> render_submit()

    assert html =~ "DNS Profile created successfully."
    assert html =~ "Kids Filter"
    assert html =~ "DNS Profile: Kids Filter"
  end

  test "switches cloud DNS provider, preset, protocol, and toggles IPv6", %{
    conn: conn,
    default_profile: profile
  } do
    {:ok, view, html} = live(conn, ~p"/dns?id=#{profile.id}")
    assert html =~ "76.76.2.2, 76.76.10.2"

    # Switch protocol to DoH for Control D Ads & Tracking
    html =
      view
      |> element("button[phx-click=select_protocol][phx-value-protocol=doh]")
      |> render_click()

    assert html =~ "https://freedns.controld.com/p2"

    # Switch provider to Control D Community Lists
    html =
      view
      |> form("#save-upstream-dns-form", %{
        "provider" => "controld_community"
      })
      |> render_change(%{"_target" => ["provider"]})

    assert html =~ "https://freedns.controld.com/x-oisd"

    # Switch preset to HaGeZi Pro
    html =
      view
      |> form("#save-upstream-dns-form", %{
        "provider" => "controld_community",
        "preset" => "x-hagezi-pro"
      })
      |> render_change(%{"_target" => ["preset"]})

    assert html =~ "https://freedns.controld.com/x-hagezi-pro"

    # Paste custom DoH URL -> auto-detects custom provider
    html =
      view
      |> form("#save-upstream-dns-form", %{
        "upstream_dns" => "https://dns.nextdns.io/abc123"
      })
      |> render_change(%{"_target" => ["upstream_dns"]})

    assert html =~ "https://dns.nextdns.io/abc123"
    refute html =~ "Filter Preset"

    # Save upstream DNS
    html =
      view
      |> form("#save-upstream-dns-form", %{
        "upstream_dns" => "https://dns.nextdns.io/abc123"
      })
      |> render_submit()

    assert html =~ "Upstream DNS servers updated."

    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:upstream_dns) ==
             "https://dns.nextdns.io/abc123"

    # Toggle IPv6 Blocking
    html = view |> element("button[phx-click=toggle_block_ipv6]") |> render_click()
    assert html =~ "IPv6 blocking enabled!"
    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:block_ipv6) == true
  end

  test "saves upstream DNS configurations directly", %{conn: conn, default_profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dns?id=#{profile.id}")

    html =
      view
      |> form("form[phx-submit=save_upstream_dns]", %{
        "upstream_dns" => "9.9.9.9, 149.112.112.112"
      })
      |> render_submit()

    assert html =~ "Upstream DNS servers updated."

    assert DnsConfig |> Hermit.Repo.get!(profile.id) |> Map.get(:upstream_dns) ==
             "9.9.9.9, 149.112.112.112"
  end

  test "links to services catalog and custom domain rules", %{
    conn: conn,
    default_profile: profile
  } do
    {:ok, _view, html} = live(conn, ~p"/dns?id=#{profile.id}")

    assert html =~ "Open Services Catalog"
    assert html =~ "Open Domain Rules"
    assert html =~ ~p"/dns/services"
    assert html =~ ~p"/dns/rules"
  end

  test "supports renaming the DNS profile inline", %{conn: conn, default_profile: profile} do
    {:ok, view, html} = live(conn, ~p"/dns?id=#{profile.id}")
    assert html =~ "DNS Profile: Default DNS Profile"

    html = view |> element("button[phx-click=start_edit_name]") |> render_click()
    assert html =~ "id=\"edit-profile-name-form\""

    html = view |> element("button[phx-click=cancel_edit_name]") |> render_click()
    assert html =~ "DNS Profile: Default DNS Profile"
    refute html =~ "id=\"edit-profile-name-form\""

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

  test "supports pausing and resuming query logs streaming", %{
    conn: conn,
    default_profile: profile
  } do
    {:ok, view, html} = live(conn, ~p"/dns?id=#{profile.id}")
    assert html =~ "Pause Stream"
    refute html =~ "(Paused)"

    html = view |> element("button[phx-click=toggle_pause_logs]") |> render_click()
    assert html =~ "Resume Stream"
    assert html =~ "(Paused)"

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

    html = view |> element("button[phx-click=toggle_pause_logs]") |> render_click()
    assert html =~ "Pause Stream"
    refute html =~ "(Paused)"

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
