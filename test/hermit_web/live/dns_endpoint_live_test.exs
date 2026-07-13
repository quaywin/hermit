defmodule HermitWeb.DnsEndpointLiveTest do
  use HermitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Hermit.Vpn.DnsConfig
  alias Hermit.Vpn.DnsEndpoint
  alias Hermit.Vpn.InboundProfile

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Hermit.Repo, {:shared, self()})
    :ok
  end

  test "renders endpoints list, creates, and deletes DoH endpoint", %{conn: conn} do
    # Create a DNS Profile first
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Test DNS Profile",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    {:ok, view, html} = live(conn, ~p"/dns/endpoints")

    assert html =~ "DNS Endpoints"
    assert html =~ "No DNS Endpoints yet"

    # Click create button to open modal
    html = view |> element("button#create-endpoint-btn") |> render_click()
    assert html =~ "Create DNS Endpoint"

    # Submit the form to create a DoH endpoint
    html =
      view
      |> form("form[phx-submit=save_new]", %{
        "dns_endpoint" => %{
          "name" => "My Personal iPhone",
          "dns_profile_id" => to_string(config.id),
          "inbound_profile_id" => ""
        }
      })
      |> render_submit()

    assert html =~ "DNS Endpoint created successfully"
    assert html =~ "My Personal iPhone"
    assert html =~ "DoH Only"
    assert html =~ "dns-query"

    # Verify endpoint exists in DB
    endpoint = Hermit.Repo.get_by(DnsEndpoint, name: "My Personal iPhone")
    assert endpoint != nil
    assert endpoint.inbound_profile_id == nil

    # Delete the endpoint
    html =
      view
      |> element("button[phx-click=\"delete_endpoint\"][phx-value-id=\"#{endpoint.id}\"]")
      |> render_click()

    assert html =~ "DNS Endpoint deleted successfully"
    refute html =~ "My Personal iPhone"
  end

  test "toggles Tailscale connection and override dns on endpoint", %{conn: conn} do
    # Create DNS Config
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Tailscale DNS Profile",
        enabled: true,
        upstream_dns: "8.8.8.8",
        custom_rules: []
      })

    # Create Inbound Profile
    {:ok, inbound} =
      Hermit.Repo.insert(%InboundProfile{
        name: "Inbound_TS",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-endpoint-test"}
      })

    # Create Endpoint linked to Tailscale Inbound
    {:ok, endpoint} =
      Hermit.Repo.insert(%DnsEndpoint{
        name: "TS Endpoint",
        dns_profile_id: config.id,
        inbound_profile_id: inbound.id,
        enabled: false,
        doh_token: "ts_endpoint_token"
      })

    {:ok, view, html} = live(conn, ~p"/dns/endpoints")

    assert html =~ "TS Endpoint"
    assert html =~ "Tailscale Connection"
    # Status is initially stopped
    assert html =~ "stopped"

    # 1. Toggle connection to enabled (Status becomes starting -> running in mock)
    view
    |> element("button[phx-click=\"toggle_endpoint_enabled\"][phx-value-id=\"#{endpoint.id}\"]")
    |> render_click()

    html = wait_until_running(view)
    assert html =~ "DNS Endpoint activated"
    assert html =~ "running"
    assert html =~ "100.64.0.100"

    # 2. Toggle Override DNS
    html =
      view
      |> element("button[phx-click=\"toggle_override_dns\"][phx-value-id=\"#{endpoint.id}\"]")
      |> render_click()

    assert html =~ "Tailscale DNS Override enabled"

    # Verify db update
    updated_config = DnsConfig.get_for_endpoint(endpoint.id)
    assert updated_config.tailscale_override_dns == true

    # Cleanup
    Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)
  end

  defp wait_until_running(view, retries \\ 20) do
    html = render(view)

    if html =~ "running" or retries == 0 do
      html
    else
      Process.sleep(100)
      wait_until_running(view, retries - 1)
    end
  end
end
