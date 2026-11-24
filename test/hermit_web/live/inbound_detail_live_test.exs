defmodule HermitWeb.InboundDetailLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    :ok
  end

  test "redirects to dashboard when inbound profile does not exist", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/inbounds"}}} = live(conn, "/inbounds/9999")
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

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound",
        type: "wireguard",
        config: %{"wg_config" => "[Interface]\nPrivateKey = pkey\n"}
      })

    {:ok, _vpn_pair} =
      Hermit.Repo.insert(%Hermit.Vpn.VpnPair{
        pair_id: "test_linked_pair",
        inbound_profile_id: inbound_profile.id,
        outbound_profile_id: outbound_profile.id,
        status: "running",
        wg_status: "stopped",
        ts_status: "stopped",
        inbound_config: %{
          "ts_auth_key" => "tskey-old",
          "advertise_exit_node" => true
        }
      })

    html =
      view
      |> form("#edit-inbound-profile-form", valid_form)
      |> render_submit()

    assert html =~ "Inbound Profile updated successfully"
    assert html =~ "inbound_updated"

    # Verify update in DB for both profile and linked VPN pairs
    updated = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated.name == "inbound_updated"
    assert updated.config["ts_auth_key"] == "tskey-new"

    updated_pair = Hermit.Repo.get!(Hermit.Vpn.VpnPair, "test_linked_pair")
    assert updated_pair.inbound_config["ts_auth_key"] == "tskey-new"
    assert updated_pair.inbound_config["advertise_exit_node"] == true
  end

  test "delete_inbound via details view", %{conn: conn} do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "inbound_delete_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-delete"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=config")
    assert html =~ "Delete Profile"

    # Click delete profile
    view |> element("button[phx-click=delete_inbound]") |> render_click()

    # Verify profile is deleted
    assert Hermit.Repo.get(Hermit.Vpn.InboundProfile, inbound_profile.id) == nil
  end

  test "renders active tunnels in routing overview and supports refresh", %{
    conn: conn
  } do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "external_routing_test",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-ext-123"}
      })

    {:ok, outbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.OutboundProfile{
        name: "test_outbound",
        type: "wireguard",
        config: %{}
      })

    _pair =
      Hermit.Repo.insert!(%Hermit.Vpn.VpnPair{
        pair_id: "routing_pair",
        inbound_profile_id: inbound_profile.id,
        outbound_profile_id: outbound_profile.id,
        status: "running",
        wg_status: "running",
        ts_status: "running",
        inbound_config: %{
          "advertise_exit_node" => true,
          "advertise_tags" => "tag:hermit"
        }
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=routing")

    assert html =~ "Tailscale Routing Overview"
    assert html =~ "routing_pair"
    assert html =~ "tag:hermit"
    assert html =~ "Active"

    # Test refresh button
    html =
      view
      |> element("button[phx-click=refresh_routing]")
      |> render_click()

    assert html =~ "Routing overview refreshed."
  end

  test "saves tailscale_dns_mode on tailscale inbound profile without wiping existing fields", %{
    conn: conn
  } do
    {:ok, inbound_profile} =
      Hermit.Repo.insert(%Hermit.Vpn.InboundProfile{
        name: "dns_mode_test_ts",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-client-123", "ts_tailnet" => "example.ts.net"}
      })

    {:ok, view, html} = live(conn, ~p"/inbounds/#{inbound_profile.id}?tab=config")
    assert html =~ "Tailscale DNS Mode"

    html =
      view
      |> form("#edit-inbound-profile-form", %{
        "inbound_profile" => %{
          "name" => "dns_mode_test_ts",
          "type" => "tailscale",
          "config" => %{
            "ts_auth_key" => "tskey-client-123",
            "ts_tailnet" => "example.ts.net",
            "tailscale_dns_mode" => "global"
          }
        }
      })
      |> render_submit()

    assert html =~ "Inbound Profile updated successfully"

    updated = Hermit.Repo.get!(Hermit.Vpn.InboundProfile, inbound_profile.id)
    assert updated.config["tailscale_dns_mode"] == "global"
    assert updated.config["ts_auth_key"] == "tskey-client-123"
    assert updated.config["ts_tailnet"] == "example.ts.net"
  end
end
