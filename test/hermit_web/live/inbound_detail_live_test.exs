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
