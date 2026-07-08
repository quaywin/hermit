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
    view |> element("button[phx-click=toggle_dns_enabled]") |> render_click()
    html = wait_until_running(view)
    assert html =~ "DNS Filtering enabled for profile."
    assert html =~ "Centralized DNS Node Running"
    assert html =~ "100.64.0.100"

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
    {:ok, _view2, _html} = live(conn, ~p"/inbounds/#{p2.id}?tab=dns")

    # Enable on p1 via UI
    _ = view1 |> element("button[phx-click=toggle_dns_enabled]") |> render_click()

    # Write configs directly to DB instead of using legacy UI forms
    {:ok, _} = Hermit.Vpn.DnsConfig.update_for_profile(p1.id, %{
      custom_rules: [%{"domain" => "profile1.com", "action" => "block"}]
    })
    {:ok, _} = Hermit.Vpn.DnsConfig.update_for_profile(p2.id, %{
      custom_rules: [%{"domain" => "profile2.com", "action" => "block"}]
    })

    # Verify both configurations are distinct in database
    c1 = Hermit.Vpn.DnsConfig.get_for_profile(p1.id)
    c2 = Hermit.Vpn.DnsConfig.get_for_profile(p2.id)

    assert c1.enabled == true
    assert Enum.map(c1.custom_rules, & &1["domain"]) == ["profile1.com"]

    assert c2.enabled == false
    assert Enum.map(c2.custom_rules, & &1["domain"]) == ["profile2.com"]

    # Verify processes in supervision tree
    assert {s1, _, _} = wait_for_status(p1.id, :running)
    assert s1 == :running

    assert {s2, _, _} = Hermit.Vpn.DnsWorker.get_status(p2.id)
    assert s2 == :stopped

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(p1.id)
    Hermit.Vpn.DnsSupervisor.stop_dns(p2.id)
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

  test "reconnect button and disabled override toggle when DNS node is not running", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_reconnect_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-reconnect"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=dns")

    # 1. DNS is disabled by default. Override DNS button must be disabled.
    assert html =~ "disabled"
    assert html =~ "Requires Centralized DNS Node to be running"

    # 2. Toggle DNS Enabled (Status changes to active/running in mock mode)
    view |> element("button[phx-click=toggle_dns_enabled]") |> render_click()
    html = wait_until_running(view)
    assert html =~ "DNS Filtering enabled for profile"
    assert html =~ "Centralized DNS Node Running"
    refute html =~ "Requires Centralized DNS Node to be running"

    # Toggle Tailscale Override DNS to true
    html = view |> element("button[phx-click=toggle_override_dns]") |> render_click()
    assert html =~ "Tailscale DNS integration enabled"

    # 3. Simulate DNS node crash/offline by stopping the DNS worker
    Hermit.Vpn.DnsSupervisor.stop_dns(inbound_profile.id)
    # Trigger a tick or page update to refresh status
    send(view.pid, :tick)
    html = render(view)

    assert html =~ "Centralized DNS Node Offline"
    assert html =~ "Reconnect Node"
    assert html =~ "Requires Centralized DNS Node to be running"

    # Verify that toggle_override_dns is disabled in the UI
    assert has_element?(view, "button[phx-click=toggle_override_dns][disabled]")

    # Verify that toggle_override_dns cannot be triggered when not running
    html = render_click(view, :toggle_override_dns, %{})
    assert html =~ "Cannot toggle Override DNS when DNS Node is not running"

    # 4. Click Reconnect Node
    view |> element("button[phx-click=reconnect_dns]") |> render_click()
    html = wait_until_running(view)
    assert html =~ "Reconnecting DNS Node"
    assert html =~ "Centralized DNS Node Running"

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(inbound_profile.id)
  end

  test "updates linked DNS profile via select form", %{conn: conn} do
    # Create two DNS Configs
    {:ok, dns_config1} = Hermit.Repo.insert(%Hermit.Vpn.DnsConfig{name: "Test DNS Profile 1", custom_rules: [], enabled: true})
    {:ok, dns_config2} = Hermit.Repo.insert(%Hermit.Vpn.DnsConfig{name: "Test DNS Profile 2", custom_rules: [], enabled: true})

    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_dropdown_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-dns-dropdown"},
        dns_profile_id: dns_config1.id
      })

    # Start the DNS worker and verify it is running
    {:ok, _} = Hermit.Vpn.DnsSupervisor.start_dns(inbound_profile.id)
    assert {status, _, _} = wait_for_status(inbound_profile.id, :running)
    assert status == :running

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=dns")

    assert html =~ "Test DNS Profile 1"
    assert html =~ "Test DNS Profile 2"

    # Select Test DNS Profile 2 and submit the form
    html =
      view
      |> form("#select-dns-profile-form", %{
        "dns_profile_id" => to_string(dns_config2.id)
      })
      |> render_submit()

    assert html =~ "Linked DNS Profile updated successfully"

    # Verify DNS worker did not stop and is still running!
    assert {status_after, _, _} = Hermit.Vpn.DnsWorker.get_status(inbound_profile.id)
    assert status_after == :running

    # Verify db update
    updated_profile = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated_profile.dns_profile_id == dns_config2.id

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(inbound_profile.id)
  end

  defp wait_until_running(view, retries \\ 20) do
    html = render(view)
    if html =~ "Centralized DNS Node Running" or retries == 0 do
      html
    else
      Process.sleep(100)
      wait_until_running(view, retries - 1)
    end
  end

  defp wait_for_status(profile_id, expected_status, retries \\ 20) do
    case Hermit.Vpn.DnsWorker.get_status(profile_id) do
      {^expected_status, ip, err} ->
        {expected_status, ip, err}

      _ ->
        if retries == 0 do
          Hermit.Vpn.DnsWorker.get_status(profile_id)
        else
          Process.sleep(100)
          wait_for_status(profile_id, expected_status, retries - 1)
        end
    end
  end
end
