defmodule HermitWeb.InboundLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  test "renders inbound profiles list, creates and deletes a profile", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/inbounds")

    assert html =~ "Inbound Profiles"
    assert html =~ "No Inbound Profiles configured yet"

    # Open Modal
    view |> element("button[phx-click=open_create_modal]") |> render_click()

    # Submit invalid form
    invalid_form = %{
      "inbound_profile" => %{
        "name" => "",
        "type" => "tailscale"
      }
    }

    html =
      view
      |> form("form[phx-submit=save_inbound]", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"

    # Submit valid form
    valid_form = %{
      "inbound_profile" => %{
        "name" => "TS Inbound Office",
        "type" => "tailscale",
        "config" => %{
          "ts_auth_key" => "tskey-auth-12345"
        }
      }
    }

    html =
      view
      |> form("form[phx-submit=save_inbound]", valid_form)
      |> render_submit()

    assert html =~ "Inbound Profile created successfully"
    assert html =~ "TS Inbound Office"

    # Delete the profile
    # Get profile ID to trigger delete action
    profile = Hermit.Repo.one!(from(p in Hermit.Vpn.InboundProfile, where: p.name == "TS Inbound Office"))

    html =
      view
      |> element("#delete-inbound-#{profile.id}")
      |> render_click()

    assert html =~ "Inbound Profile deleted"
    refute html =~ "TS Inbound Office"
  end
end
