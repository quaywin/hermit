defmodule HermitWeb.ProviderImportLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Hermit.Repo
  alias Hermit.Vpn.ProviderConfig
  alias Hermit.Vpn.OutboundProfile

  setup do
    # Clear DB before each test
    Repo.delete_all(ProviderConfig)
    Repo.delete_all(OutboundProfile)
    :ok
  end

  test "renders provider import, fetches and imports NordVPN recommended servers", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/providers")

    assert html =~ "VPN Providers Import"
    assert html =~ "NordVPN"
    assert html =~ "Fetch Servers"

    # Fill NordVPN forms and submit Fetch Servers
    html =
      view
      |> form("#nordvpn-form", %{
        "access_token" => "nord_test_access_token",
        "limit" => "30"
      })
      |> render_change()

    assert html =~ "nord_test_access_token"

    # Select United States as country using custom dropdown select
    view
    |> element("input[name=nord_country_name]")
    |> render_focus()

    view
    |> element("li[phx-click=select_nord_country_item][phx-value-id='228']")
    |> render_click()

    # Trigger Fetch Servers
    view
    |> element("button", "Fetch Servers")
    |> render_click()

    # Wait a small moment for async task to process
    :timer.sleep(50)

    # Render again to get updated view
    html = render(view)

    assert html =~ "United States #1"
    assert html =~ "United States #2"

    # Select the first server
    view
    |> element("input[type=checkbox][phx-value-id='1']")
    |> render_click()

    # Click Import Outbounds
    html =
      view
      |> element("button", "Import Selected (1) Outbounds")
      |> render_click()

    assert html =~ "Successfully imported 1 profiles"
    assert html =~ "Saved VPN Configurations (1)"
    assert html =~ "NordVPN - US - United States #1"

    # Verify that the ProviderConfig has been created in DB
    assert Repo.one(from(p in ProviderConfig, select: count(p.id))) == 1
    config = Repo.one(from(p in ProviderConfig, limit: 1))
    assert config.name =~ "NordVPN - US - United States #1"
    assert config.provider == "nordvpn"
    assert config.config["wg_config"] =~ "PrivateKey = mocked_private_key_from_token"
    assert config.config["wg_config"] =~ "Endpoint = 1.1.1.1:51820"
  end

  test "saves credentials and auto-populates on reload", %{conn: conn} do
    # Clear settings first
    Repo.delete_all(Hermit.Vpn.Setting)

    {:ok, view, _html} = live(conn, ~p"/providers")

    # 1. Save NordVPN credentials
    view
    |> form("#nordvpn-form", %{
      "access_token" => "saved_nord_token"
    })
    |> render_change()

    html =
      view
      |> element("button", "Save Credentials")
      |> render_click()

    assert html =~ "NordVPN Credentials saved successfully"
    assert Hermit.Vpn.Setting.get_value("nord_access_token") == "saved_nord_token"

    # Reload the page and verify auto-population
    {:ok, _new_view, html} = live(conn, ~p"/providers")
    assert html =~ "saved_nord_token"

    # 2. Create a config to test delete functionality
    config =
      Repo.insert!(%Hermit.Vpn.ProviderConfig{
        name: "Config to Delete",
        provider: "custom",
        config: %{"wg_config" => "[Interface]\n"}
      })

    # Reload to see the new config in list
    {:ok, view, html} = live(conn, ~p"/providers")
    assert html =~ "Config to Delete"
    assert html =~ "Saved VPN Configurations (1)"

    # Click delete button
    html =
      view
      |> element("#delete-config-#{config.id}")
      |> render_click()

    assert html =~ "Saved VPN Configuration deleted"
    refute html =~ "Config to Delete"
    assert Repo.one(from(p in ProviderConfig, select: count(p.id))) == 0
  end

  test "renders provider import, switches to Custom Conf Import and pastes manual config", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/providers")

    # Switch tab to Custom Conf Import
    html =
      view
      |> element("button", "Custom Conf Import")
      |> render_click()

    assert html =~ "Upload .conf Files"
    assert html =~ "Manual Paste"

    # Paste raw config
    raw_config = """
    [Interface]
    PrivateKey = test_custom_key
    Address = 10.0.0.2/24

    [Peer]
    PublicKey = peer_key
    Endpoint = 9.9.9.9:51820
    """

    html =
      view
      |> form("form", %{
        "paste_name" => "My Custom WG Provider",
        "paste_text" => raw_config
      })
      |> render_submit()

    assert html =~ "Successfully imported 1 profiles"

    # Verify DB
    assert Repo.one(from(p in ProviderConfig, select: count(p.id))) == 1
    config = Repo.one(from(p in ProviderConfig, limit: 1))
    assert config.name == "My Custom WG Provider"
    assert config.provider == "custom"
    assert config.config["wg_config"] == raw_config
  end

  test "auto-fills fields when dropping a .conf file in Custom Conf Import", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/providers")

    # Switch tab to Custom Conf Import
    view
    |> element("button", "Custom Conf Import")
    |> render_click()

    # Simulate dropping/uploading a file
    conf_file =
      file_input(view, "#bulk-import-form", :wg_files, [
        %{
          name: "my_custom_server.conf",
          content: "[Interface]\nPrivateKey = upload_test_key\nAddress = 10.9.9.9/32\n"
        }
      ])

    # Uploading the file automatically triggers progress and fills the form
    html = render_upload(conf_file, "my_custom_server.conf")

    # The fields should be filled immediately
    assert html =~ "my_custom_server"
    assert html =~ "upload_test_key"
    assert html =~ "10.9.9.9/32"

    # Now click submit to save it to DB
    html =
      view
      |> form("#bulk-import-form", %{
        "paste_name" => "my_custom_server",
        "paste_text" => "[Interface]\nPrivateKey = upload_test_key\nAddress = 10.9.9.9/32\n"
      })
      |> render_submit()

    assert html =~ "Successfully imported 1 profiles"

    # Verify DB
    assert Repo.one(from(p in ProviderConfig, select: count(p.id))) == 1
    # Find config by name
    config = Repo.get_by!(ProviderConfig, name: "my_custom_server")
    assert config.provider == "custom"
    assert config.config["wg_config"] =~ "PrivateKey = upload_test_key"
  end

  test "filters countries list by typing in search input", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/providers")

    # Focus to open dropdown
    html =
      view
      |> element("input[name=nord_country_name]")
      |> render_focus()

    # Dropdown should display both countries
    assert html =~ "United States"
    assert html =~ "Singapore"

    # Search for "Sing" using keyup on the search input
    html =
      view
      |> element("input[name=nord_country_name]")
      |> render_keyup(%{"value" => "Sing"})

    # Singapore should remain, United States should be filtered out
    assert html =~ "Singapore"
    refute html =~ "United States (US)"

    # Select Singapore
    html =
      view
      |> element("li[phx-click=select_nord_country_item][phx-value-id='194']")
      |> render_click()

    # Dropdown should be closed (no select items in DOM anymore, though input value is Singapore)
    refute html =~ "select_nord_country_item"
  end
end
