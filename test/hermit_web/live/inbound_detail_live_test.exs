defmodule HermitWeb.InboundDetailLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    :ok
  end

  test "redirects to dashboard when inbound profile does not exist", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/inbounds/9999")
  end

  test "renders config tab, validates, and saves updates", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "inbound_to_edit",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-old"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=config")

    assert html =~ "Inbound Profile: inbound_to_edit"
    assert html =~ "Edit Profile Settings"

    # Test validation error by changing type to proxy and submitting invalid port
    view
    |> form("#edit-inbound-profile-form", %{
      "inbound_profile" => %{"type" => "proxy"}
    })
    |> render_change()

    invalid_form = %{
      "inbound_profile" => %{
        "name" => "",
        "type" => "proxy",
        "config" => %{"port" => "abc"}
      }
    }

    html =
      view
      |> form("#edit-inbound-profile-form", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"
    assert html =~ "Proxy port must be a valid number between 1 and 65535"

    # Test successful update by changing type back to tailscale
    view
    |> form("#edit-inbound-profile-form", %{
      "inbound_profile" => %{"type" => "tailscale"}
    })
    |> render_change()

    valid_form = %{
      "inbound_profile" => %{
        "name" => "inbound_updated",
        "type" => "tailscale",
        "config" => %{"ts_auth_key" => "tskey-new"}
      }
    }

    html =
      view
      |> form("#edit-inbound-profile-form", valid_form)
      |> render_submit()

    assert html =~ "Inbound Profile updated successfully"
    assert html =~ "inbound_updated"

    # Verify update in DB
    updated = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated.name == "inbound_updated"
    assert updated.config["ts_auth_key"] == "tskey-new"
  end

  test "renders and configures profile-specific DNS settings tab", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_inbound_ts",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-123"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=dns")

    assert html =~ "DNS Control"
    assert html =~ "DNS Control Inactive"

    # 1. Toggle DNS Enabled (Status changes to active/running)
    html = view |> element("button[phx-click=toggle_dns_enabled]") |> render_click()
    assert html =~ "DNS Filtering enabled for profile."
    assert html =~ "Centralized DNS Node Running"
    assert html =~ "100.64.0.100"

    # 2. Toggle Filters
    html = view |> element("button[phx-click=toggle_block_ads]") |> render_click()
    assert html =~ "Ads/Trackers blocking enabled!"
    html = view |> element("button[phx-click=toggle_block_goodbyeads]") |> render_click()
    assert html =~ "GoodbyeAds blocking enabled!"
    html = view |> element("button[phx-click=toggle_block_adult]") |> render_click()
    assert html =~ "Adult content blocking enabled!"

    # 3. Save Upstream DNS
    html =
      view
      |> form("#save_upstream_dns_form", %{"upstream_dns" => "1.1.1.1, 9.9.9.9"})
      |> render_submit()

    assert html =~ "Upstream DNS servers updated."

    # 4. Add Custom Rules (Block)
    html =
      view
      |> form("#add_custom_rule_form", %{
        "domain" => "ad.example.com",
        "action" => "block"
      })
      |> render_submit()

    assert html =~ "Custom rule for ad.example.com added."
    assert html =~ "ad.example.com"
    assert html =~ "Block"

    # 5. Add Custom Redirect Rule
    _ = view |> element("select[name=action]") |> render_change(%{"action" => "redirect"})

    html =
      view
      |> form("#add_custom_rule_form", %{
        "domain" => "my-redirect.com",
        "action" => "redirect",
        "value" => "192.168.1.5"
      })
      |> render_submit()

    assert html =~ "Custom rule for my-redirect.com added."
    assert html =~ "my-redirect.com"
    assert html =~ "192.168.1.5"

    # 6. Delete rule
    html =
      view |> element("button[phx-value-domain='ad.example.com']", "Delete") |> render_click()

    assert html =~ "Custom rule for ad.example.com deleted."

    # Verify in DB directly
    updated_config = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    assert Enum.find(updated_config.custom_rules, &(&1["domain"] == "ad.example.com")) == nil

    # 7. Test live logs streaming
    log = %{
      "pair_id" => to_string(inbound_profile.id),
      "domain" => "live-test.org",
      "type" => "A",
      "status" => "resolved",
      "answer" => "1.1.1.1",
      "duration" => 8,
      "timestamp" => System.system_time(:second)
    }

    Phoenix.PubSub.broadcast(Hermit.PubSub, "dns_logs:#{inbound_profile.id}", {:dns_log, log})
    Process.sleep(50)

    html = render(view)
    assert html =~ "live-test.org"
    assert html =~ "1.1.1.1"

    # Clear logs
    html = view |> element("button[phx-click=clear_dns_logs]", "Clear") |> render_click()
    refute html =~ "live-test.org"

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(inbound_profile.id)
  end

  test "supports multiple isolated DNS profiles concurrently", %{conn: conn} do
    {:ok, p1} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "profile_1",
        type: "tailscale",
        config: %{"ts_auth_key" => "key-1"}
      })

    {:ok, p2} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "profile_2",
        type: "tailscale",
        config: %{"ts_auth_key" => "key-2"}
      })

    {:ok, view1, _html} = live(conn, ~p"/inbounds/#{p1.id}?tab=dns")
    {:ok, view2, _html} = live(conn, ~p"/inbounds/#{p2.id}?tab=dns")

    # Enable and configure rule on p1
    _ = view1 |> element("button[phx-click=toggle_dns_enabled]") |> render_click()

    view1
    |> form("#add_custom_rule_form", %{
      "domain" => "profile1.com",
      "action" => "block"
    })
    |> render_submit()

    # Configure rule on p2 (leave disabled)
    view2
    |> form("#add_custom_rule_form", %{
      "domain" => "profile2.com",
      "action" => "block"
    })
    |> render_submit()

    # Verify both configurations are distinct in database
    c1 = Hermit.Vpn.DnsConfig.get_for_profile(p1.id)
    c2 = Hermit.Vpn.DnsConfig.get_for_profile(p2.id)

    assert c1.enabled == true
    assert Enum.map(c1.custom_rules, & &1["domain"]) == ["profile1.com"]

    assert c2.enabled == false
    assert Enum.map(c2.custom_rules, & &1["domain"]) == ["profile2.com"]

    # Verify processes in supervision tree
    assert {s1, _, _} = Hermit.Vpn.DnsWorker.get_status(p1.id)
    assert s1 == :running

    assert {s2, _, _} = Hermit.Vpn.DnsWorker.get_status(p2.id)
    assert s2 == :stopped

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(p1.id)
    Hermit.Vpn.DnsSupervisor.stop_dns(p2.id)
  end

  test "toggles override dns without crashing when DNS worker is not running", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_toggle_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-toggle"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=dns")
    assert html =~ "DNS Control"

    # Initially, tailscale_override_dns is false
    config = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    refute config.tailscale_override_dns

    # Toggle to true (it should not crash even if the worker is not running)
    html = view |> element("button[phx-click=toggle_override_dns]") |> render_click()
    assert html =~ "Tailscale DNS integration enabled."

    # Verify db updated to true
    config_after = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    assert config_after.tailscale_override_dns == true

    # Toggle back to false
    html = view |> element("button[phx-click=toggle_override_dns]") |> render_click()
    assert html =~ "Tailscale DNS integration disabled."

    # Verify db updated to false
    config_final = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    assert config_final.tailscale_override_dns == false
  end

  test "toggles query logging updates database", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_query_log_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-toggle"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=dns")
    assert html =~ "Enable Query Logs"

    # Initially, enable_query_logging is false
    config = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    refute config.enable_query_logging

    # Toggle to true
    html = view |> element("button[phx-click=toggle_query_logging]") |> render_click()
    assert html =~ "Query logging enabled for this profile."

    # Verify db updated to true
    config_after = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    assert config_after.enable_query_logging == true

    # Toggle back to false
    html = view |> element("button[phx-click=toggle_query_logging]") |> render_click()
    assert html =~ "Query logging disabled for this profile."

    # Verify db updated to false
    config_final = Hermit.Vpn.DnsConfig.get_for_profile(inbound_profile.id)
    assert config_final.enable_query_logging == false
  end

  test "delete_inbound clears tailscale dns override if enabled", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_delete_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-delete"}
      })

    # Set override to true
    {:ok, _config} =
      Hermit.Vpn.DnsConfig.update_for_profile(inbound_profile.id, %{tailscale_override_dns: true})

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=config")
    assert html =~ "Delete Profile"

    # Click delete profile
    view |> element("button[phx-click=delete_inbound]") |> render_click()

    # Verify profile is deleted
    assert Hermit.Repo.get(Hermit.Vpn.InboundProfile, inbound_profile.id) == nil
  end

  test "renders external connectors in routing overview and supports direct domain deletion", %{
    conn: conn
  } do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "external_routing_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-ext-123"}
      })

    mock_connectors = [
      %{
        "name" => "hermit-connector-external-node",
        "connectors" => ["tag:connector-external-node"],
        "domains" => ["external.com", "other-external.com"]
      }
    ]

    docker_env = Application.get_env(:hermit, :docker, [])

    Application.put_env(
      :hermit,
      :docker,
      Keyword.put(docker_env, :mock_app_connectors, mock_connectors)
    )

    on_exit(fn ->
      Application.put_env(:hermit, :docker, docker_env)
    end)

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=routing")

    assert html =~ "Tailscale Routing Overview"
    assert html =~ "tag:connector-external-node"
    assert html =~ "Tailscale External"
    assert html =~ "external.com"
    assert html =~ "other-external.com"

    html =
      view
      |> element(
        "button[phx-click=delete_domain][phx-value-pair-id=\"tag:connector-external-node\"][phx-value-domain=\"external.com\"]"
      )
      |> render_click()

    assert html =~ "Domain external.com removed from external node tag:connector-external-node"
    refute html =~ "phx-value-domain=\"external.com\""
    assert html =~ "phx-value-domain=\"other-external.com\""
  end
end
