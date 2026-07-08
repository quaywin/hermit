defmodule HermitWeb.OutboundLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  test "renders outbound profiles list, creates, edits and deletes a profile", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/outbounds")

    assert html =~ "Outbound Profiles"

    # Open Modal
    view |> element("button[phx-click=open_create_modal]") |> render_click()

    # Submit invalid form
    invalid_form = %{
      "outbound_profile" => %{
        "name" => "",
        "type" => "wireguard"
      }
    }

    html =
      view
      |> form("#outbound-profile-form", invalid_form)
      |> render_change()

    assert html =~ "can&#39;t be blank"

    # Submit valid form
    valid_form = %{
      "outbound_profile" => %{
        "name" => "Mullvad WG US",
        "type" => "wireguard",
        "config" => %{
          "wg_config" => "[Interface]\nPrivateKey = outbound_test_key\n"
        }
      }
    }

    html =
      view
      |> form("#outbound-profile-form", valid_form)
      |> render_submit()

    assert html =~ "Outbound Profile created successfully"
    assert html =~ "Mullvad WG US"

    # Get profile ID
    profile = Hermit.Repo.one!(from(p in Hermit.Vpn.OutboundProfile, where: p.name == "Mullvad WG US"))

    # Edit the profile
    html =
      view
      |> element("#edit-outbound-#{profile.id}")
      |> render_click()

    assert html =~ "Edit Outbound Profile"

    # Save edit with updated name
    edit_form = %{
      "outbound_profile" => %{
        "name" => "Mullvad WG US Updated",
        "type" => "wireguard",
        "config" => %{
          "wg_config" => "[Interface]\nPrivateKey = outbound_test_key_updated\n"
        }
      }
    }

    html =
      view
      |> form("#edit-outbound-profile-form", edit_form)
      |> render_submit()

    assert html =~ "Outbound Profile updated successfully"
    assert html =~ "Mullvad WG US Updated"

    # Delete the profile
    html =
      view
      |> element("#delete-outbound-#{profile.id}")
      |> render_click()

    assert html =~ "Outbound Profile deleted"
    refute html =~ "Mullvad WG US Updated"
  end
end
