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

  test "renders endpoints list, creates, and deletes Tailscale DNS endpoint", %{conn: conn} do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Test DNS Profile",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    {:ok, inbound} =
      Hermit.Repo.insert(%InboundProfile{
        name: "Home Tailnet",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-test-create"}
      })

    {:ok, view, html} = live(conn, ~p"/dns/endpoints")

    assert html =~ "DNS Endpoints"
    assert html =~ "No DNS Endpoints yet"

    html = view |> element("button#create-endpoint-btn") |> render_click()
    assert html =~ "Create DNS Endpoint"

    html =
      view
      |> form("form[phx-submit=save_new]", %{
        "dns_endpoint" => %{
          "name" => "My Home Tailnet DNS",
          "dns_profile_id" => to_string(config.id),
          "inbound_profile_id" => to_string(inbound.id)
        }
      })
      |> render_submit()

    assert html =~ "DNS Endpoint created successfully"
    assert html =~ "My Home Tailnet DNS"
    assert html =~ "Tailscale Connection"
    assert html =~ "Home Tailnet"

    endpoint = Hermit.Repo.get_by(DnsEndpoint, name: "My Home Tailnet DNS")
    assert endpoint != nil
    assert endpoint.inbound_profile_id == inbound.id

    html =
      view
      |> element("button[phx-click=\"delete_endpoint\"][phx-value-id=\"#{endpoint.id}\"]")
      |> render_click()

    assert html =~ "DNS Endpoint deleted successfully"
    refute html =~ "My Home Tailnet DNS"
  end

  test "toggles Tailscale connection and override dns on endpoint", %{conn: conn} do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Tailscale DNS Profile",
        enabled: true,
        upstream_dns: "8.8.8.8",
        custom_rules: []
      })

    {:ok, inbound} =
      Hermit.Repo.insert(%InboundProfile{
        name: "Inbound_TS",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-endpoint-test"}
      })

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
    assert html =~ "stopped"

    view
    |> element("button[phx-click=\"toggle_endpoint_enabled\"][phx-value-id=\"#{endpoint.id}\"]")
    |> render_click()

    html = wait_until_running(view)
    assert html =~ "DNS Endpoint activated"
    assert html =~ "running"
    assert html =~ "100.64.0.100"

    html =
      view
      |> element("button[phx-click=\"toggle_override_dns\"][phx-value-id=\"#{endpoint.id}\"]")
      |> render_click()

    assert html =~ "Tailscale DNS Override enabled"

    updated_config = DnsConfig.get_for_endpoint(endpoint.id)
    assert updated_config.tailscale_override_dns == true

    Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)
  end

  test "updates running DNS server when switching dns_profile_id via quick_select and edit modal",
       %{conn: conn} do
    {:ok, p1} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Profile Alpha",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    {:ok, p2} =
      Hermit.Repo.insert(%DnsConfig{
        name: "Profile Beta",
        enabled: true,
        upstream_dns: "8.8.8.8",
        custom_rules: []
      })

    {:ok, inbound} =
      Hermit.Repo.insert(%InboundProfile{
        name: "Switch Test TS",
        type: "tailscale",
        config: %{"ts_auth_key" => "tskey-switch-test"}
      })

    {:ok, endpoint} =
      Hermit.Repo.insert(%DnsEndpoint{
        name: "TS Switch EP",
        dns_profile_id: p1.id,
        inbound_profile_id: inbound.id,
        enabled: true,
        doh_token: "ts_switch_token_live"
      })

    {:ok, {_, _server_pid}} = Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, inbound.id)

    [{_, {initial_config, _}}] =
      :ets.lookup(:inbound_profiles_cache, {:endpoint_config, endpoint.id})

    assert initial_config.id == p1.id
    assert initial_config.upstream_dns == "1.1.1.1"

    {:ok, view, _html} = live(conn, ~p"/dns/endpoints")

    view
    |> form("#quick-select-dns-form-#{endpoint.id}")
    |> render_change(%{
      "endpoint_id" => to_string(endpoint.id),
      "dns_profile_id" => to_string(p2.id)
    })

    [{_, {updated_config, _}}] =
      :ets.lookup(:inbound_profiles_cache, {:endpoint_config, endpoint.id})

    assert updated_config.id == p2.id
    assert updated_config.upstream_dns == "8.8.8.8"

    view
    |> element("button[phx-click=\"edit_endpoint\"][phx-value-id=\"#{endpoint.id}\"]")
    |> render_click()

    view
    |> form("#edit-endpoint-form", %{
      "dns_endpoint" => %{
        "name" => "TS Switch EP Renamed",
        "dns_profile_id" => to_string(p1.id),
        "inbound_profile_id" => to_string(inbound.id)
      }
    })
    |> render_submit()

    [{_, {final_config, _}}] =
      :ets.lookup(:inbound_profiles_cache, {:endpoint_config, endpoint.id})

    assert final_config.id == p1.id
    assert final_config.upstream_dns == "1.1.1.1"

    Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)
  end

  test "prevents activating an endpoint without an inbound profile", %{conn: conn} do
    {:ok, config} =
      Hermit.Repo.insert(%DnsConfig{
        name: "No Inbound Profile",
        enabled: true,
        upstream_dns: "1.1.1.1",
        custom_rules: []
      })

    {:ok, endpoint} =
      Hermit.Repo.insert(%DnsEndpoint{
        name: "Unassigned Endpoint",
        dns_profile_id: config.id,
        inbound_profile_id: nil,
        enabled: false,
        doh_token: "orphan_token"
      })

    {:ok, view, _html} = live(conn, ~p"/dns/endpoints")

    # 1. UI renders button as disabled
    assert has_element?(
             view,
             "button[phx-click=\"toggle_endpoint_enabled\"][phx-value-id=\"#{endpoint.id}\"][disabled]"
           )

    # 2. Server-side event guard blocks direct activation attempt
    html = render_hook(view, "toggle_endpoint_enabled", %{"id" => to_string(endpoint.id)})
    assert html =~ "Cannot activate endpoint"
    refute Hermit.Repo.get!(DnsEndpoint, endpoint.id).enabled
  end

  defp wait_until_running(view, retries \\ 30) do
    send(view.pid, :tick)
    html = render(view)

    if (html =~ "100.64.0.100" and html =~ "running") or retries == 0 do
      html
    else
      Process.sleep(100)
      wait_until_running(view, retries - 1)
    end
  end
end
